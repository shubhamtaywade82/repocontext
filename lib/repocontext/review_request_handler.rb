# frozen_string_literal: true

module RepoContext
  # Single responsibility: run the code review flow and return structured result.
  # Depends on code_review_agent.
  class ReviewRequestHandler
    def initialize(review_agent:, logger: Settings.logger)
      @review_agent = review_agent
      @log = logger
    end

    def call(paths:, focus:)
      state = @review_agent.run(request_paths: paths, focus: focus)
      {
        findings: state.findings,
        summary: state.observations.last,
        reviewed_paths: state.reviewed_paths,
        iterations: state.iteration
      }
    end
  end
end
