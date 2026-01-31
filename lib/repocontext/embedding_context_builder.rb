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
      @index_cache = { mutex: Mutex.new, index: nil, repo: nil }
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
      @index_cache[:mutex].synchronize do
        return @index_cache[:index] if @index_cache[:index] && @index_cache[:repo] == @repo_root

        @log.info { "building embedding index (model=#{Settings::OLLAMA_EMBED_MODEL})..." }
        chunks = chunk_repo
        index = index_chunks_with_embeddings(chunks)
        @index_cache[:index] = index
        @index_cache[:repo] = @repo_root
        @log.info { "embedding index built: #{index.size} chunks" }
        index
      end
    end

    def index_chunks_with_embeddings(chunks)
      chunks.map do |c|
        vec = embed_string(c[:text])
        { path: c[:path], text: c[:text], embedding: vec }
      end
    end

    def chunk_repo
      paths = @candidate_paths_source.is_a?(Array) ? @candidate_paths_source : @candidate_paths_source.call
      chunks = []
      paths.each do |rel_path|
        break if chunks.size >= Settings::EMBED_MAX_CHUNKS

        full_path = File.join(@repo_root, rel_path)
        next unless File.file?(full_path)

        append_chunks_from_file(full_path, rel_path, chunks)
      end
      chunks
    end

    def append_chunks_from_file(full_path, rel_path, chunks)
      content = File.read(full_path)
      chunk_text(content, rel_path).each do |c|
        chunks << c
        return if chunks.size >= Settings::EMBED_MAX_CHUNKS
      end
    end

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
