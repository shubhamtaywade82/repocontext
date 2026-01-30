# frozen_string_literal: true

module RepoContext
  # Result of reviewing one file (or the summary step): findings, optional observation, optional path.
  class FileReviewOutcome
    attr_reader :findings, :observation, :reviewed_path

    def initialize(findings:, observation: nil, reviewed_path: nil)
      @findings = findings.freeze
      @observation = observation&.strip
      @reviewed_path = reviewed_path&.strip
    end

    def self.with_no_findings(reviewed_path: nil)
      new(findings: [], observation: nil, reviewed_path: reviewed_path)
    end
  end
end
