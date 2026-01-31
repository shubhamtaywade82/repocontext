# frozen_string_literal: true

module RepoContext
  # Agentic code review loop: plan → execute → observe until done.
  # Depends on abstractions: path_source (duck type: candidate_paths), planner, executor, summary_writer.
  class CodeReviewAgent
    # Common patterns to exclude from code review
    EXCLUDED_PATTERNS = [
      "**/node_modules/**",
      "**/vendor/**",
      "**/.git/**",
      "**/dist/**",
      "**/build/**",
      "**/*.min.js",
      "**/*.bundle.js",
      "**/*.lock",
      "**/package-lock.json",
      "**/Gemfile.lock"
    ].freeze

    # Binary file extensions to skip
    BINARY_EXTENSIONS = %w[
      .jpg .jpeg .png .gif .bmp .ico .svg
      .pdf .zip .tar .gz .tgz .rar .7z
      .exe .dll .so .dylib .bin
      .mp3 .mp4 .avi .mov .wav
      .woff .woff2 .ttf .eot
    ].freeze
    def initialize(
      path_source:,
      planner:,
      executor:,
      summary_writer:,
      logger: Settings.logger
    )
      @path_source = path_source
      @planner = planner
      @executor = executor
      @summary_writer = summary_writer
      @log = logger
    end

    def run(request_paths: [], focus: Settings::REVIEW_FOCUS, &event_callback)
      paths_to_review = resolve_paths_to_review(request_paths)
      current_state = ReviewState.new(request_paths: paths_to_review, focus: focus)

      yield_event(event_callback, :init, 0, { paths: paths_to_review })

      Settings::REVIEW_MAX_ITERATIONS.times do
        yield_event(event_callback, :plan, current_state.iteration, nil)
        if Settings.shutdown_requested?
          @log.info { "shutdown requested, stopping review" }
          yield_event(event_callback, :done, current_state.iteration, current_state)
          return current_state
        end

        plan_step = @planner.next_step(current_state, paths_to_review)
        if plan_step.done?
          current_state = run_summary_and_emit(current_state, event_callback)
          yield_event(event_callback, :done, current_state.iteration, current_state)
          return current_state
        end

        next unless plan_step.review_file? && plan_step.target

        current_state = process_review_file_step(
          plan_step,
          current_state,
          paths_to_review,
          event_callback
        )
        if Settings.shutdown_requested?
          yield_event(event_callback, :done, current_state.iteration, current_state)
          return current_state
        end
      end

      yield_event(event_callback, :done, current_state.iteration, current_state)
      current_state
    end

    def run_with_events(request_paths: [], focus: Settings::REVIEW_FOCUS, &block)
      run(request_paths: request_paths, focus: focus, &block)
    end

    private

    def resolve_paths_to_review(request_paths)
      paths = request_paths.any? ? request_paths : @path_source.candidate_paths
      filtered = paths.select { |p| reviewable_file?(p) }
      limited = filtered.first(Settings::REVIEW_MAX_PATHS)

      skipped_count = paths.size - filtered.size
      @log.info { "review paths: #{limited.size} selected, #{skipped_count} filtered" } if skipped_count > 0

      limited
    end

    def reviewable_file?(path)
      # Check if file exists
      full_path = File.join(Settings::REPO_ROOT, path)
      return false unless File.file?(full_path)

      # Check file size
      file_size = File.size(full_path)
      if file_size > Settings::REVIEW_MAX_FILE_SIZE
        @log.debug { "skipping large file: #{path} (#{file_size} bytes)" }
        return false
      end

      # Check excluded patterns
      if EXCLUDED_PATTERNS.any? { |pattern| File.fnmatch(pattern, path, File::FNM_PATHNAME) }
        @log.debug { "skipping excluded pattern: #{path}" }
        return false
      end

      # Check binary extensions
      ext = File.extname(path).downcase
      if BINARY_EXTENSIONS.include?(ext)
        @log.debug { "skipping binary file: #{path}" }
        return false
      end

      true
    end

    def run_summary_and_emit(current_state, event_callback)
      yield_event(event_callback, :summarize, current_state.iteration, nil)
      summary_outcome = @summary_writer.summarize(current_state)
      state_after_summary = current_state.append(summary_outcome)
      yield_event(event_callback, :summary_done, state_after_summary.iteration, summary_outcome)
      state_after_summary
    end

    def process_review_file_step(plan_step, current_state, paths_to_review, event_callback)
      file_path = resolve_file_path(plan_step.target, paths_to_review)
      unless file_path
        @log.warn { "planner target not in candidates: #{plan_step.target}" }
        return current_state
      end

      yield_event(event_callback, :review_file, current_state.iteration, file_path)
      return current_state if Settings.shutdown_requested?

      file_content = read_file_content(file_path)
      unless file_content
        @log.warn { "could not read file: #{file_path}" }
        return current_state.append(FileReviewOutcome.with_no_findings(reviewed_path: file_path))
      end

      outcome = @executor.execute(plan_step, file_content: file_content, path: file_path)
      new_state = current_state.append(outcome)
      yield_event(event_callback, :review_done, new_state.iteration, outcome)
      new_state
    end

    def yield_event(callback, event, iteration, payload)
      callback&.call(event, iteration, payload)
    end

    def resolve_file_path(target_path, paths_to_review)
      return target_path if paths_to_review.include?(target_path)
      paths_to_review.find do |candidate_path|
        candidate_path == target_path ||
          candidate_path.end_with?("/#{target_path}") ||
          File.basename(candidate_path) == target_path ||
          File.basename(candidate_path) == File.basename(target_path)
      end
    end

    def read_file_content(relative_path)
      absolute_path = File.join(Settings::REPO_ROOT, relative_path)
      File.file?(absolute_path) ? File.read(absolute_path) : nil
    end
  end
end
