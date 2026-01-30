# frozen_string_literal: true

module RepoContext
  class CodeReviewAgent
    def initialize(client:, model:, context_builder:, logger: Settings.logger)
      @client = client
      @model = model
      @context_builder = context_builder
      @log = logger
      @planner = ReviewPlanner.new(client: client, model: model, logger: logger)
      @executor = ReviewStepExecutor.new(client: client, model: model, logger: logger)
    end

    def run(request_paths: [], focus: Settings::REVIEW_FOCUS)
      candidates = request_paths.any? ? request_paths : @context_builder.candidate_paths
      candidates = candidates.first(Settings::REVIEW_MAX_PATHS)
      state = ReviewState.new(request_paths: candidates, focus: focus)

      Settings::REVIEW_MAX_ITERATIONS.times do
        plan = @planner.next_step(state, candidates)
        if plan.done?
          result = @executor.execute_summary(state)
          state = state.append(result)
          break state
        end

        next unless plan.review_file? && plan.target

        path = resolve_path(plan.target, candidates)
        unless path
          @log.warn { "planner target not in candidates: #{plan.target}" }
          next
        end

        file_content = read_file(path)
        unless file_content
          @log.warn { "could not read file: #{path}" }
          state = state.append(ReviewStepResult.empty(reviewed_path: path))
          next
        end

        result = @executor.execute(plan, file_content: file_content, path: path)
        state = state.append(result)
      end

      state
    end

    def run_with_events(request_paths: [], focus: Settings::REVIEW_FOCUS, &block)
      candidates = request_paths.any? ? request_paths : @context_builder.candidate_paths
      candidates = candidates.first(Settings::REVIEW_MAX_PATHS)
      state = ReviewState.new(request_paths: candidates, focus: focus)

      Settings::REVIEW_MAX_ITERATIONS.times do
        yield :plan, state.iteration, nil
        plan = @planner.next_step(state, candidates)
        if plan.done?
          yield :summarize, state.iteration, nil
          result = @executor.execute_summary(state)
          state = state.append(result)
          yield :summary_done, state.iteration, result
          yield :done, state.iteration, state
          return state
        end

        next unless plan.review_file? && plan.target

        path = resolve_path(plan.target, candidates)
        unless path
          @log.warn { "planner target not in candidates: #{plan.target}" }
          next
        end

        yield :review_file, state.iteration, path
        file_content = read_file(path)
        unless file_content
          @log.warn { "could not read file: #{path}" }
          state = state.append(ReviewStepResult.empty(reviewed_path: path))
          next
        end

        result = @executor.execute(plan, file_content: file_content, path: path)
        state = state.append(result)
        yield :review_done, state.iteration, result
      end

      yield :done, state.iteration, state
      state
    end

    private

    def resolve_path(target, candidates)
      return target if candidates.include?(target)
      candidates.find { |c| c == target || c.end_with?("/#{target}") || File.basename(c) == target }
    end

    def read_file(path)
      full = File.join(Settings::REPO_ROOT, path)
      return nil unless File.file?(full)
      File.read(full)
    end
  end
end
