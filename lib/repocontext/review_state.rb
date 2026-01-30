# frozen_string_literal: true

module RepoContext
  class ReviewState
    attr_reader :request_paths, :focus, :reviewed_paths, :findings, :iteration, :observations

    def initialize(request_paths:, focus:, reviewed_paths: [], findings: [], iteration: 0, observations: [])
      @request_paths = request_paths.freeze
      @focus = focus.to_s.freeze
      @reviewed_paths = reviewed_paths.dup.freeze
      @findings = findings.dup.freeze
      @iteration = iteration
      @observations = observations.dup.freeze
    end

    def append(outcome)
      new_reviewed = outcome.reviewed_path ? (reviewed_paths + [outcome.reviewed_path]) : reviewed_paths
      new_findings = findings + outcome.findings
      new_observations = observations + [outcome.observation].compact
      self.class.new(
        request_paths: request_paths,
        focus: focus,
        reviewed_paths: new_reviewed,
        findings: new_findings,
        iteration: iteration + 1,
        observations: new_observations
      )
    end

    def remaining_candidates(candidate_paths)
      (Array(candidate_paths) - reviewed_paths).uniq
    end

    def summary_for_planner
      lines = []
      lines << "Focus: #{focus}"
      lines << "Reviewed (#{reviewed_paths.size}): #{reviewed_paths.join(', ')}" if reviewed_paths.any?
      lines << "Findings so far: #{findings.size}"
      observations.last(3).each { |o| lines << "Observation: #{o}" } if observations.any?
      lines.join("\n")
    end
  end
end
