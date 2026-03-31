# frozen_string_literal: true

module RepoContext
  # Single responsibility: review one file and return findings (FileReviewOutcome).
  # Dependencies: client (LLM duck: #generate(prompt:, schema:, model:)), model (string), logger.
  class ReviewStepExecutor
    DEFAULT_FOCUS = "general quality"
    SEVERITIES = %w[suggestion warning error].freeze
    DEFAULT_SEVERITY = "suggestion"

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
              "severity" => { "type" => "string", "enum" => SEVERITIES }
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
      @log.warn { "executor failed for #{path}: #{e.class} - #{e.message}" }
      FileReviewOutcome.with_observation("Review failed: #{e.message}", reviewed_path: path)
    end

    private

    def build_review_prompt(plan_step, file_content, path)
      focus = plan_step.reasoning.to_s.strip.empty? ? DEFAULT_FOCUS : plan_step.reasoning
      instruction = review_instruction(focus)
      file_section = file_section(path, file_content)
      <<~PROMPT
        #{instruction}

        #{file_section}

        Return JSON with:
        - "findings": array of { "file" (optional), "line" (optional number), "rule" (e.g. "naming", "method_length"), "message" (short), "severity" ("suggestion" | "warning" | "error") }
        - "observation": one short sentence summarizing this file (optional)
      PROMPT
    end

    def review_instruction(focus)
      <<~TEXT.strip
        You are a code reviewer. Review focus: #{focus}.

        Apply Clean Ruby style: clear names, single responsibility, short methods, guard clauses, no deep nesting, intention-revealing names. Flag style issues, possible bugs, and unclear code.
      TEXT
    end

    def file_section(path, file_content)
      "File: #{path}\n\n--- file content ---\n#{file_content}\n--- end ---"
    end

    def normalize_findings(raw, default_path)
      raw.filter_map do |h|
        next unless h.is_a?(Hash) && h["message"].to_s.strip != ""

        severity = h["severity"].to_s
        severity = DEFAULT_SEVERITY unless SEVERITIES.include?(severity)
        {
          "file" => (h["file"].to_s.strip.empty? ? default_path : h["file"].to_s.strip),
          "line" => h["line"].nil? ? nil : h["line"].to_i,
          "rule" => h["rule"].to_s.strip,
          "message" => h["message"].to_s.strip,
          "severity" => severity
        }
      end
    end
  end
end
