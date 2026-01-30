# frozen_string_literal: true

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
      return "" unless Settings::EMBED_CONTEXT_ENABLED && Settings::EMBED_TOP_K.positive?

      index = build_index
      return "" if index.empty?

      query_vec = @client.embeddings.embed(model: Settings::OLLAMA_EMBED_MODEL, input: question)
      top_chunks = top_chunks_by_similarity(index, query_vec)
      assemble_context(top_chunks, max_chars)
    rescue Ollama::Error => e
      @log.warn { "embed context failed: #{e.message}" }
      ""
    end

    private

    def build_index
      @index_cache[:mutex].synchronize do
        return @index_cache[:index] if @index_cache[:index] && @index_cache[:repo] == @repo_root

        @log.info { "building embedding index (model=#{Settings::OLLAMA_EMBED_MODEL})..." }
        chunks = chunk_repo
        index = chunks.map do |c|
          vec = @client.embeddings.embed(model: Settings::OLLAMA_EMBED_MODEL, input: c[:text])
          { path: c[:path], text: c[:text], embedding: vec }
        end
        @index_cache[:index] = index
        @index_cache[:repo] = @repo_root
        @log.info { "embedding index built: #{index.size} chunks" }
        index
      end
    end

    def chunk_repo
      paths = @candidate_paths_source.is_a?(Array) ? @candidate_paths_source : @candidate_paths_source.call
      chunks = []
      paths.each do |rel_path|
        break if chunks.size >= Settings::EMBED_MAX_CHUNKS

        full = File.join(@repo_root, rel_path)
        next unless File.file?(full)

        content = File.read(full)
        chunk_text(content, rel_path).each { |c| chunks << c; break if chunks.size >= Settings::EMBED_MAX_CHUNKS }
      end
      chunks
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
  end
end
