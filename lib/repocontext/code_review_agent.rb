# frozen_string_literal: true

module RepoContext
  class CodeReviewAgent
    def initialize(client:, model:, context_builder:, logger: Settings.logger)
      @ollama_client = client
      @model_name = model
      @repo_context_builder = context_builder
      @log = logger
      @planner = ReviewPlanner.new(client: client, model: model, logger: logger)
      @executor = ReviewStepExecutor.new(client: client, model: model, logger: logger)
    end

    def run(request_paths: [], focus: Settings::REVIEW_FOCUS, &event_callback)
      candidate_path_list = resolve_candidate_paths(request_paths)
      review_state = ReviewState.new(request_paths: candidate_path_list, focus: focus)

      Settings::REVIEW_MAX_ITERATIONS.times do
        yield_event(event_callback, :plan, review_state.iteration, nil)

        plan_step = @planner.next_step(review_state, candidate_path_list)
        if plan_step.done?
          review_state = run_summary_and_finish(review_state, event_callback)
          yield_event(event_callback, :done, review_state.iteration, review_state)
          return review_state
        end

        next unless plan_step.review_file? && plan_step.target

        file_path = resolve_file_path(plan_step.target, candidate_path_list)
        unless file_path
          @log.warn { "planner target not in candidates: #{plan_step.target}" }
          next
        end

        yield_event(event_callback, :review_file, review_state.iteration, file_path)

        file_content = read_file_content(file_path)
        unless file_content
          @log.warn { "could not read file: #{file_path}" }
          review_state = review_state.append(FileReviewOutcome.with_no_findings(reviewed_path: file_path))
          next
        end

        outcome = @executor.execute(plan_step, file_content: file_content, path: file_path)
        review_state = review_state.append(outcome)
        yield_event(event_callback, :review_done, review_state.iteration, outcome)
      end

      yield_event(event_callback, :done, review_state.iteration, review_state)
      review_state
    end

    def run_with_events(request_paths: [], focus: Settings::REVIEW_FOCUS, &block)
      run(request_paths: request_paths, focus: focus, &block)
    end

    private

    def resolve_candidate_paths(request_paths)
      path_list = request_paths.any? ? request_paths : @repo_context_builder.candidate_paths
      path_list.first(Settings::REVIEW_MAX_PATHS)
    end

    def run_summary_and_finish(review_state, event_callback)
      yield_event(event_callback, :summarize, review_state.iteration, nil)
      summary_outcome = @executor.execute_summary(review_state)
      new_state = review_state.append(summary_outcome)
      yield_event(event_callback, :summary_done, new_state.iteration, summary_outcome)
      new_state
    end

    def yield_event(callback, event, iteration, payload)
      callback&.call(event, iteration, payload)
    end

    def resolve_file_path(target_path, candidate_path_list)
      return target_path if candidate_path_list.include?(target_path)
      candidate_path_list.find do |candidate_path|
        candidate_path == target_path ||
          candidate_path.end_with?("/#{target_path}") ||
          File.basename(candidate_path) == target_path
      end
    end

    def read_file_content(relative_path)
      absolute_path = File.join(Settings::REPO_ROOT, relative_path)
      File.file?(absolute_path) ? File.read(absolute_path) : nil
    end
  end
end
