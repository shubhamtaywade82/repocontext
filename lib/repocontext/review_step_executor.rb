# frozen_string_literal: true

module RepoContext
  # Single responsibility: review one file and return findings (FileReviewOutcome).
  class ReviewStepExecutor
    FINDINGS_SCHEMA = {
      "type" => "object",
      "required" => ["findings"],
      "properties" => {
        "findings" => {
          "type" => "array",
          "items" => {
            "type" => "object",
            "required" => %w[message],
            "properties" => {
              "file" => { "type" => "string" },
              "line" => { "type" => ["integer", "null"] },
              "rule" => { "type" => "string" },
              "message" => { "type" => "string" },
              "severity" => { "type" => "string", "enum" => %w[suggestion warning error] }
            }
          }
        },
        "observation" => { "type" => "string" }
      }
    }.freeze

    def initialize(client:, model:, logger: Settings.logger)
      @client = client
      @model = model
      @log = logger
    end

    def execute(plan_step, file_content:, path:)
      prompt = build_review_prompt(plan_step, file_content, path)
      response = @client.generate(prompt: prompt, schema: FINDINGS_SCHEMA, model: @model)
      findings = normalize_findings(Array(response["findings"]), path)
      observation = response["observation"].to_s.strip
      observation = nil if observation.empty?
      @log.info { "executor: #{findings.size} finding(s) for #{path}" }
      FileReviewOutcome.new(findings: findings, observation: observation, reviewed_path: path)
    rescue Ollama::Error => e
      @log.warn { "executor failed for #{path}: #{e.message}" }
      FileReviewOutcome.new(
        findings: [],
        observation: "Review failed: #{e.message}",
        reviewed_path: path
      )
    end

    private

    def build_review_prompt(plan_step, file_content, path)
      <<~PROMPT
        You are a code reviewer. Review focus: #{plan_step.reasoning || 'general quality'}.

        Apply Clean Ruby style: clear names, single responsibility, short methods, guard clauses, no deep nesting, intention-revealing names. Flag style issues, possible bugs, and unclear code.

        File: #{path}

        --- file content ---
        #{file_content}
        --- end ---

        Return JSON with:
        - "findings": array of { "file" (optional), "line" (optional number), "rule" (e.g. "naming", "method_length"), "message" (short), "severity" ("suggestion" | "warning" | "error") }
        - "observation": one short sentence summarizing this file (optional)
      PROMPT
    end

    def normalize_findings(raw, default_path)
      raw.filter_map do |h|
        next unless h.is_a?(Hash) && h["message"].to_s.strip != ""

        {
          "file" => (h["file"].to_s.strip.empty? ? default_path : h["file"].to_s.strip),
          "line" => h["line"].nil? ? nil : h["line"].to_i,
          "rule" => h["rule"].to_s.strip,
          "message" => h["message"].to_s.strip,
          "severity" => %w[suggestion warning error].include?(h["severity"].to_s) ? h["severity"].to_s : "suggestion"
        }
      end
    end
  end
end
