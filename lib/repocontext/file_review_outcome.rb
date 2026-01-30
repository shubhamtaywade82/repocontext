# frozen_string_literal: true

module RepoContext
  # Outcome of reviewing a single file (or the summary step): findings list, optional observation, optional path.
  # Use .with_no_findings(reviewed_path: path) for a class-level factory when no findings were produced.
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
