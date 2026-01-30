# frozen_string_literal: true

module RepoContext
  class ReviewState
    INITIAL_ITERATION = 0

    attr_reader :request_paths, :focus, :reviewed_paths, :findings, :iteration, :observations

    def initialize(request_paths:, focus:, reviewed_paths: [], findings: [], iteration: INITIAL_ITERATION, observations: [])
      @request_paths = request_paths.freeze
      @focus = focus.to_s.freeze
      @reviewed_paths = reviewed_paths.dup.freeze
      @findings = findings.dup.freeze
      @iteration = iteration
      @observations = observations.dup.freeze
    end

    def append(outcome)
      updated_reviewed = outcome.reviewed_path ? (@reviewed_paths + [outcome.reviewed_path]) : @reviewed_paths
      updated_findings = @findings + outcome.findings
      updated_observations = @observations + [outcome.observation].compact
      self.class.new(
        request_paths: @request_paths,
        focus: @focus,
        reviewed_paths: updated_reviewed,
        findings: updated_findings,
        iteration: @iteration + 1,
        observations: updated_observations
      )
    end

    def remaining_candidates(candidate_paths)
      (Array(candidate_paths) - @reviewed_paths).uniq
    end

    def summary_for_planner
      lines = []
      lines << "Focus: #{@focus}"
      lines << "Reviewed (#{@reviewed_paths.size}): #{@reviewed_paths.join(', ')}" if @reviewed_paths.any?
      lines << "Findings so far: #{@findings.size}"
      @observations.last(3).each { |obs| lines << "Observation: #{obs}" } if @observations.any?
      lines.join("\n")
    end
  end
end
