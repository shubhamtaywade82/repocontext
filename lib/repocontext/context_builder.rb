# frozen_string_literal: true

require "set"

module RepoContext
  class ContextBuilder
    DISCOVERY_SCHEMA = {
      "type" => "object",
      "required" => ["paths"],
      "properties" => { "paths" => { "type" => "array", "items" => { "type" => "string" } } }
    }.freeze

    def initialize(client:, model:, logger: Settings.logger)
      @client = client
      @model = model
      @log = logger
      @embed_index_cache = { mutex: Mutex.new, index: nil, repo: nil }
    end

    def candidate_paths
      candidate_paths_for_discovery
    end

    def gather(question)
      base_context = load_repo_context
      used_chars = base_context.size
      loaded_paths = base_loaded_paths

      base_context = append_embed_context(base_context, question, used_chars) if Settings::EMBED_CONTEXT_ENABLED
      used_chars = base_context.size

      base_context, loaded_paths = append_boost_paths(base_context, question, used_chars, loaded_paths)
      used_chars = base_context.size

      base_context = append_discovery_context(base_context, question, loaded_paths) if Settings::DISCOVERY_AGENT_ENABLED
      base_context
    end

    private

    def load_files_into_context(files, existing_paths: Set.new, max_chars: Settings::CONTEXT_MAX_CHARS)
      total = 0
      result = []
      repo_root = Settings::REPO_ROOT

      files.each do |name|
        path = File.join(repo_root, name.strip)
        next unless File.file?(path)
        next if existing_paths.include?(File.expand_path(path))

        content = File.read(path)
        room = max_chars - total
        if content.size <= room
          total += content.size
          result << "--- #{name.strip} ---\n#{content}"
        elsif room > 0
          result << "--- #{name.strip} (first #{room} chars) ---\n#{content[0, room]}"
          @log.info { "truncated #{name.strip} to #{room} chars (file size #{content.size})" }
          break
        else
          break
        end
      end
      result
    end

    def load_repo_context(files = Settings::REFERENCE_FILES, max_chars: Settings::CONTEXT_MAX_CHARS)
      loaded_chunks = load_files_into_context(files, max_chars: max_chars)
      if loaded_chunks.empty? && files == Settings::REFERENCE_FILES
        @log.info { "repo context: no #{Settings::REFERENCE_FILES.join(',')} in #{Settings::REPO_ROOT}, trying fallback: #{Settings::FALLBACK_CONTEXT_FILES.join(',')}" }
        return load_repo_context(Settings::FALLBACK_CONTEXT_FILES, max_chars: max_chars)
      end
      @log.info { "repo context: #{loaded_chunks.size} file(s), #{loaded_chunks.join.size} chars total" }
      loaded_chunks.join("\n\n")
    end

    def candidate_paths_for_discovery
      dirs = ["."]
      %w[app lib config docs].each { |d| dirs << d if Dir.exist?(File.join(Settings::REPO_ROOT, d)) }
      paths = []
      dirs.each do |dir|
        full = dir == "." ? Settings::REPO_ROOT : File.join(Settings::REPO_ROOT, dir)
        next unless Dir.exist?(full)

        pattern = dir == "." ? "*.{rb,md,json}" : "*/*.{rb,md,json}"
        Dir.glob(File.join(full, pattern)).each do |p|
          paths << p.delete_prefix("#{Settings::REPO_ROOT}/") if File.file?(p)
          break if paths.size >= Settings::CANDIDATE_PATHS_MAX
        end
        break if paths.size >= Settings::CANDIDATE_PATHS_MAX
      end
      paths.uniq.first(Settings::CANDIDATE_PATHS_MAX)
    end

    def discovery_agent_pick_paths(question, candidate_paths)
      return [] if candidate_paths.empty?

      prompt = <<~PROMPT
        User question about the codebase: #{question}

        List of file paths in the repo (one per line):
        #{candidate_paths.first(60).join("\n")}

        Return a JSON object with one key "paths": an array of up to #{Settings::DISCOVERY_PATHS_MAX} paths from the list above that are most relevant to answer the question. Use exact path strings from the list.
      PROMPT
      out = @client.generate(prompt: prompt, schema: DISCOVERY_SCHEMA, model: @model)
      chosen = Array(out["paths"]).first(Settings::DISCOVERY_PATHS_MAX)
      @log.info { "discovery agent: picked #{chosen.size} path(s): #{chosen.join(', ')}" }
      chosen
    rescue Ollama::Error => e
      @log.warn { "discovery agent failed: #{e.message}, using base context only" }
      []
    end

    def cosine_similarity(a, b)
      return 0.0 if a.size != b.size || a.empty?
      dot = a.zip(b).sum { |x, y| x * y }
      norm_a = Math.sqrt(a.sum { |x| x * x })
      norm_b = Math.sqrt(b.sum { |x| x * x })
      return 0.0 if norm_a.zero? || norm_b.zero?
      dot / (norm_a * norm_b)
    end

    def chunk_text(text, path, chunk_size:, overlap:)
      chunks = []
      start = 0
      while start < text.size && chunks.size < Settings::EMBED_MAX_CHUNKS
        slice = text[start, chunk_size]
        break if slice.nil? || slice.empty?
        chunks << { path: path, text: slice }
        start += chunk_size - overlap
      end
      chunks
    end

    def chunk_repo_for_embedding
      paths = candidate_paths_for_discovery
      chunks = []
      paths.each do |rel_path|
        break if chunks.size >= Settings::EMBED_MAX_CHUNKS
        full = File.join(Settings::REPO_ROOT, rel_path)
        next unless File.file?(full)
        content = File.read(full)
        chunk_text(content, rel_path, chunk_size: Settings::EMBED_CHUNK_SIZE, overlap: Settings::EMBED_CHUNK_OVERLAP).each do |c|
          chunks << c
          break if chunks.size >= Settings::EMBED_MAX_CHUNKS
        end
      end
      chunks
    end

    def build_embedding_index
      cache = @embed_index_cache
      cache[:mutex].synchronize do
        return cache[:index] if cache[:index] && cache[:repo] == Settings::REPO_ROOT
        @log.info { "building embedding index (model=#{Settings::OLLAMA_EMBED_MODEL}, max_chunks=#{Settings::EMBED_MAX_CHUNKS})..." }
        raw = chunk_repo_for_embedding
        index = []
        raw.each_with_index do |c, i|
          vec = @client.embeddings.embed(model: Settings::OLLAMA_EMBED_MODEL, input: c[:text])
          index << { path: c[:path], text: c[:text], embedding: vec }
          @log.debug { "embedded chunk #{i + 1}/#{raw.size} #{c[:path]}" } if (i + 1) % 20 == 0
        end
        cache[:index] = index
        cache[:repo] = Settings::REPO_ROOT
        @log.info { "embedding index built: #{index.size} chunks" }
        index
      end
    end

    def embed_context_for_question(question, max_chars:)
      return "" unless Settings::EMBED_CONTEXT_ENABLED && Settings::EMBED_TOP_K.positive?
      index = build_embedding_index
      return "" if index.empty?
      q_vec = @client.embeddings.embed(model: Settings::OLLAMA_EMBED_MODEL, input: question)
      scored = index.map { |c| [c, cosine_similarity(q_vec, c[:embedding])] }.sort_by { |_, s| -s }
      top = scored.first(Settings::EMBED_TOP_K).map(&:first)
      total = 0
      parts = []
      top.each do |c|
        part = "--- #{c[:path]} ---\n#{c[:text]}"
        break if total + part.size > max_chars
        parts << part
        total += part.size
      end
      return "" if parts.empty?
      @log.info { "embed context: #{parts.size} chunks, #{total} chars" }
      parts.join("\n\n")
    rescue Ollama::Error => e
      @log.warn { "embed context failed: #{e.message}, skipping" }
      ""
    end

    def base_loaded_paths
      (Settings::REFERENCE_FILES + Settings::FALLBACK_CONTEXT_FILES).filter_map do |name|
        path = File.join(Settings::REPO_ROOT, name.strip)
        File.expand_path(path) if File.file?(path)
      end.to_set
    end

    def pascal_to_snake(str)
      str.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').gsub(/([a-z\d])([A-Z])/, '\1_\2').downcase
    end

    def question_boost_paths(question)
      paths = []
      question.scan(/\b([A-Z][a-zA-Z]*)\s+model\b/) do |match|
        name = match[0].to_s.strip
        next if name.empty?
        snake = pascal_to_snake(name)
        %w[app/models lib].each do |dir|
          candidate = "#{dir}/#{snake}.rb"
          path = File.join(Settings::REPO_ROOT, candidate)
          if File.file?(path)
            paths << candidate
            break
          end
        end
      end
      paths.uniq
    end

    def append_embed_context(base, question, used_size)
      embed_room = Settings::CONTEXT_MAX_CHARS - used_size
      embed_block = embed_context_for_question(question, max_chars: embed_room)
      return base if embed_block.empty?
      @log.info { "context after embeddings: #{base.size + embed_block.size} chars" }
      "#{base}\n\n#{embed_block}"
    end

    def append_boost_paths(base, question, used_size, existing)
      boost_paths = question_boost_paths(question)
      return [base, existing] if boost_paths.empty?
      remaining = Settings::CONTEXT_MAX_CHARS - used_size
      boost_loaded = load_files_into_context(boost_paths, existing_paths: existing, max_chars: remaining)
      return [base, existing] if boost_loaded.empty?
      new_existing = existing + boost_paths.map { |p| File.expand_path(File.join(Settings::REPO_ROOT, p)) }.to_set
      @log.info { "context after question boost (#{boost_paths.join(', ')}): #{base.size + boost_loaded.join.size} chars" }
      ["#{base}\n\n#{boost_loaded.join("\n\n")}", new_existing]
    end

    def append_discovery_context(base_context, question, already_loaded_paths)
      candidate_path_list = candidate_paths_for_discovery
      return base_context if candidate_path_list.empty?

      chosen_paths = discovery_agent_pick_paths(question, candidate_path_list)
      return base_context if chosen_paths.empty?

      remaining_chars = Settings::CONTEXT_MAX_CHARS - base_context.size
      discovery_chunks = load_files_into_context(chosen_paths, existing_paths: already_loaded_paths, max_chars: remaining_chars)
      return base_context if discovery_chunks.empty?

      @log.info { "context after discovery: #{base_context.size + discovery_chunks.join.size} chars" }
      "#{base_context}\n\n#{discovery_chunks.join("\n\n")}"
    end
  end
end
