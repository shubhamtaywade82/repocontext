# frozen_string_literal: true

module RepoContext
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
      plan_response = @client.generate(prompt: prompt, schema: FINDINGS_SCHEMA, model: @model)
      findings = normalize_findings(Array(plan_response["findings"]), path)
      observation = plan_response["observation"].to_s.strip
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

    def execute_summary(state)
      return FileReviewOutcome.with_no_findings(reviewed_path: nil) if state.findings.empty? && state.reviewed_paths.empty?

      prompt = build_summary_prompt(state)
      plan_response = @client.generate(prompt: prompt, schema: SUMMARY_SCHEMA, model: @model)
      summary_text = plan_response["summary"].to_s.strip
      summary_text = "No summary produced." if summary_text.empty?
      @log.info { "executor: summary produced" }
      FileReviewOutcome.new(findings: [], observation: summary_text, reviewed_path: nil)
    rescue Ollama::Error => e
      @log.warn { "summary failed: #{e.message}" }
      FileReviewOutcome.new(findings: [], observation: "Summary failed: #{e.message}", reviewed_path: nil)
    end

    private

    SUMMARY_SCHEMA = {
      "type" => "object",
      "required" => ["summary"],
      "properties" => { "summary" => { "type" => "string" } }
    }.freeze

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

    def build_summary_prompt(state)
      findings_text = state.findings.empty? ? "No findings." : state.findings.map { |f| "[#{f['severity']}] #{f['file']}#{f['line'] ? ":#{f['line']}" : ''} #{f['rule']}: #{f['message']}" }.join("\n")
      <<~PROMPT
        Code review summary. Focus was: #{state.focus}
        Files reviewed: #{state.reviewed_paths.join(', ')}
        Findings:
        #{findings_text}

        Return JSON with one key "summary": a short paragraph for the developer (priorities, main risks, and one or two concrete next steps).
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
