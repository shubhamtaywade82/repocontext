# frozen_string_literal: true

module RepoContext
  # Agentic code review loop: plan → execute → observe until done.
  # Depends on abstractions: path_source (duck type: candidate_paths), planner, executor, summary_writer.
  class CodeReviewAgent
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
      paths.first(Settings::REVIEW_MAX_PATHS)
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
