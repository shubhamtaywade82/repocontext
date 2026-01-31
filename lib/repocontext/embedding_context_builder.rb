# frozen_string_literal: true
require "net/http"
require "uri"
require "json"

module RepoContext
  # Single responsibility: build embedding index and retrieve relevant context for a question.
  class EmbeddingContextBuilder
    def initialize(client:, repo_root:, candidate_paths_source:, logger: Settings.logger)
      @client = client
      @repo_root = repo_root
      @candidate_paths_source = candidate_paths_source
      @log = logger
      @store = VectorStore.new(repo_root: repo_root, logger: logger)
    end

    def context_for_question(question, max_chars:)
      return "" unless Settings::EMBED_CONTEXT_ENABLED
      return "" if Settings::EMBED_TOP_K <= 0
      return "" if max_chars <= 0
      return "" unless question_worth_embedding?(question)

      index = build_index
      return "" if index.empty?

      vec = embed_string(question.to_s.strip)
      return "" if vec.empty?

      top_chunks = top_chunks_by_similarity(index, vec)
      assemble_context(top_chunks, max_chars)
    rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED => e
      @log.warn { "embed context failed (#{e.class}): #{e.message}" }
      ""
    rescue StandardError => e
      @log.warn { "embed context failed (#{e.class}): #{e.message}" }
      ""
    end

    private

    def question_worth_embedding?(question)
      return false if question.nil?
      stripped = question.to_s.strip
      stripped.size >= Settings::EMBED_MIN_QUESTION_LENGTH
    end

    def build_index
      @log.info { "building/loading embedding index..." }
      chunks = ChunkAndStore.new(
        store: @store,
        repo_root: @repo_root,
        paths_source: @candidate_paths_source,
        builder: self,
        logger: @log
      ).call
      @log.info { "embedding index ready: #{chunks.size} chunks" }
      chunks
    end

    class ChunkAndStore
      def initialize(store:, repo_root:, paths_source:, builder:, logger:)
        @store = store
        @repo_root = repo_root
        @paths_source = paths_source
        @builder = builder
        @log = logger
      end

      def call
        paths = @paths_source.is_a?(Array) ? @paths_source : @paths_source.call
        all_chunks = []

        paths.each do |rel_path|
          full_path = File.join(@repo_root, rel_path)
          next unless File.file?(full_path)

          mtime = File.mtime(full_path).to_i
          stored_mtime = @store.stored_mtime(rel_path)

          if stored_mtime == mtime
            @log.debug { "verifying #{rel_path}: unchanged" }
            stored_chunks = @store.find_chunks(rel_path)
            if stored_chunks.any?
               all_chunks.concat(stored_chunks)
               next
            end
          end

          @log.info { "indexing #{rel_path} (new/modified)..." }
          file_chunks = []
          content = File.read(full_path)

          @builder.send(:chunk_text, content, rel_path).each do |c|
            vec = @builder.send(:embed_string, c[:text])
            next if vec.empty?
            c[:embedding] = vec
            file_chunks << c
          end

          if file_chunks.any?
            @store.upsert(rel_path, mtime, file_chunks)
            all_chunks.concat(file_chunks)
          end
        end
        all_chunks
      end
    end


    # Note: embed_string and chunk_text are private, accessed via send() by ChunkAndStore

    def chunk_text(text, path)
      chunk_size = Settings::EMBED_CHUNK_SIZE
      overlap = Settings::EMBED_CHUNK_OVERLAP
      result = []
      start = 0
      while start < text.size && result.size < Settings::EMBED_MAX_CHUNKS
        slice = text[start, chunk_size]
        break if slice.nil? || slice.empty?

        result << { path: path, text: slice }
        start += chunk_size - overlap
      end
      result
    end

    def cosine_similarity(a, b)
      return 0.0 if a.size != b.size || a.empty?

      dot = a.zip(b).sum { |x, y| x * y }
      norm_a = Math.sqrt(a.sum { |x| x * x })
      norm_b = Math.sqrt(b.sum { |x| x * x })
      return 0.0 if norm_a.zero? || norm_b.zero?

      dot / (norm_a * norm_b)
    end

    def top_chunks_by_similarity(index, query_vec)
      index
        .map { |c| [c, cosine_similarity(query_vec, c[:embedding])] }
        .sort_by { |_, score| -score }
        .first(Settings::EMBED_TOP_K)
        .map(&:first)
    end

    def assemble_context(chunks, max_chars)
      total = 0
      parts = []
      chunks.each do |c|
        part = "--- #{c[:path]} ---\n#{c[:text]}"
        break if total + part.size > max_chars

        parts << part
        total += part.size
      end
      return "" if parts.empty?

      @log.info { "embed context: #{parts.size} chunks, #{total} chars" }
      parts.join("\n\n")
    end

    def embed_string(text)
      uri = URI.parse("#{Settings::OLLAMA_BASE_URL}/api/embed")
      payload = {
        model: Settings::OLLAMA_EMBED_MODEL,
        input: text
      }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.read_timeout = Settings::OLLAMA_TIMEOUT

      request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
      request.body = payload.to_json

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        @log.warn { "embed request failed: #{response.code} #{response.message}" }
        return []
      end

      json = JSON.parse(response.body)
      # /api/embed returns "embeddings": [[...]] for single string
      # fallback to "embedding" just in case mechanism differs
      json["embeddings"]&.first || json["embedding"] || []
    rescue JSON::ParserError, Timeout::Error, Errno::ECONNREFUSED => e
      @log.warn { "embed request failed: #{e.message}" }
      []
    rescue StandardError => e
      @log.warn { "embed request exception: #{e.message}" }
      []
    end
  end
end

