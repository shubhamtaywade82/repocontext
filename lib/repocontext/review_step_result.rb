# frozen_string_literal: true

module RepoContext
  class ReviewStepResult
    attr_reader :findings, :observation, :reviewed_path

    def initialize(findings:, observation: nil, reviewed_path: nil)
      @findings = findings.freeze
      @observation = observation&.strip
      @reviewed_path = reviewed_path&.strip
    end

    def self.empty(reviewed_path: nil)
      new(findings: [], observation: nil, reviewed_path: reviewed_path)
    end
  end
end
