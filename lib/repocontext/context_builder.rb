# frozen_string_literal: true

require "set"

module RepoContext
  # Orchestrates gathering repo context: base files, optional embeddings, boost paths, optional discovery.
  # Depends on abstractions: discovery_selector (candidate_paths, pick_paths), optional embedding_builder (context_for_question).
  class ContextBuilder
    def initialize(
      discovery_selector:,
      embedding_builder: nil,
      logger: Settings.logger
    )
      @discovery_selector = discovery_selector
      @embedding_builder = embedding_builder
      @log = logger
    end

    def candidate_paths
      @discovery_selector.candidate_paths
    end

    def gather(question)
      context_text = load_repo_context
      context_size_so_far = context_text.size
      paths_already_in_context = base_loaded_paths

      context_text = apply_embed_context(context_text, question, context_size_so_far)
      context_size_so_far = context_text.size

      context_text, paths_already_in_context = apply_boost_paths(
        context_text,
        question,
        context_size_so_far,
        paths_already_in_context
      )
      context_size_so_far = context_text.size

      context_text = apply_discovery_context(context_text, question, paths_already_in_context) if Settings::DISCOVERY_AGENT_ENABLED
      context_text
    end

    private

    def apply_embed_context(context_text, question, context_size_so_far)
      return context_text unless @embedding_builder

      remaining_chars = Settings::CONTEXT_MAX_CHARS - context_size_so_far
      embed_block = @embedding_builder.context_for_question(question, max_chars: remaining_chars)
      return context_text if embed_block.empty?

      @log.info { "context after embeddings: #{context_text.size + embed_block.size} chars" }
      "#{context_text}\n\n#{embed_block}"
    end

    def apply_boost_paths(context_text, question, context_size_so_far, paths_already_in_context)
      boost_paths = question_boost_paths(question)
      return [context_text, paths_already_in_context] if boost_paths.empty?

      remaining_chars = Settings::CONTEXT_MAX_CHARS - context_size_so_far
      boost_chunks = load_files_into_context(boost_paths, existing_paths: paths_already_in_context, max_chars: remaining_chars)
      return [context_text, paths_already_in_context] if boost_chunks.empty?

      paths_after_boost = paths_already_in_context + boost_paths.map { |p| File.expand_path(File.join(Settings::REPO_ROOT, p)) }.to_set
      @log.info { "context after question boost (#{boost_paths.join(', ')}): #{context_text.size + boost_chunks.join.size} chars" }
      ["#{context_text}\n\n#{boost_chunks.join("\n\n")}", paths_after_boost]
    end

    def apply_discovery_context(context_text, question, paths_already_in_context)
      candidate_path_list = @discovery_selector.candidate_paths
      return context_text if candidate_path_list.empty?

      chosen_paths = @discovery_selector.pick_paths(question, candidate_path_list)
      return context_text if chosen_paths.empty?

      remaining_chars = Settings::CONTEXT_MAX_CHARS - context_text.size
      discovery_chunks = load_files_into_context(chosen_paths, existing_paths: paths_already_in_context, max_chars: remaining_chars)
      return context_text if discovery_chunks.empty?

      @log.info { "context after discovery: #{context_text.size + discovery_chunks.join.size} chars" }
      "#{context_text}\n\n#{discovery_chunks.join("\n\n")}"
    end

    def load_files_into_context(files, existing_paths: Set.new, max_chars: Settings::CONTEXT_MAX_CHARS)
      total_chars = 0
      result = []
      repo_root = Settings::REPO_ROOT

      files.each do |name|
        path = File.join(repo_root, name.strip)
        next unless File.file?(path)
        next if existing_paths.include?(File.expand_path(path))

        content = read_file_safely(path)
        next if content.nil?

        room = max_chars - total_chars
        if content.size <= room
          total_chars += content.size
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

    def read_file_safely(path)
      File.read(path)
    rescue Errno::ENOENT, Errno::EACCES, Errno::EISDIR => e
      @log.warn { "skip #{path}: #{e.message}" }
      nil
    end

    def load_repo_context(files = Settings::REFERENCE_FILES, max_chars: Settings::CONTEXT_MAX_CHARS)
      loaded_chunks = load_files_into_context(files, max_chars: max_chars)
      if loaded_chunks.empty? && files == Settings::REFERENCE_FILES
        @log.info { "repo context: no #{Settings::REFERENCE_FILES.join(',')} in #{Settings::REPO_ROOT}, trying fallback" }
        return load_repo_context(Settings::FALLBACK_CONTEXT_FILES, max_chars: max_chars)
      end
      @log.info { "repo context: #{loaded_chunks.size} file(s), #{loaded_chunks.join.size} chars total" }
      loaded_chunks.join("\n\n")
    end

    def base_loaded_paths
      (Settings::REFERENCE_FILES + Settings::FALLBACK_CONTEXT_FILES).filter_map do |name|
        path = File.join(Settings::REPO_ROOT, name.strip)
        File.expand_path(path) if File.file?(path)
      end.to_set
    end

    # Used by question_boost_paths to infer path from "ModelName model" in question (e.g. User model -> app/models/user.rb).
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
  end
end
