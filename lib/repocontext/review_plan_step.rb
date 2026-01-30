# frozen_string_literal: true

module RepoContext
  class ReviewPlanStep
    DONE = "done"
    REVIEW_FILE = "review_file"
    SUMMARIZE = "summarize"

    attr_reader :action, :target, :reasoning

    def initialize(action:, target: nil, reasoning: nil)
      @action = action.to_s.strip
      @target = target&.strip
      @reasoning = reasoning&.strip
    end

    def done?
      action == DONE
    end

    def review_file?
      action == REVIEW_FILE
    end

    def summarize?
      action == SUMMARIZE
    end
  end
end
