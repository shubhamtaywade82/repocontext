# frozen_string_literal: true

module RepoContext
  # Outcome of reviewing a single file (or the summary step): findings list, optional observation, optional path.
  # Factories: .with_no_findings(reviewed_path:) when no findings; .with_observation(observation, reviewed_path:) for summary/error outcomes.
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

    def self.with_observation(observation, reviewed_path: nil)
      new(findings: [], observation: observation, reviewed_path: reviewed_path)
    end
  end
end
