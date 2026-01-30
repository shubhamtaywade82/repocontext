# frozen_string_literal: true

module RepoContext
  # Single responsibility: produce a summary outcome from review state (findings + paths).
  class ReviewSummaryWriter
    SUMMARY_SCHEMA = {
      "type" => "object",
      "required" => ["summary"],
      "properties" => { "summary" => { "type" => "string" } }
    }.freeze

    def initialize(client:, model:, logger: Settings.logger)
      @client = client
      @model = model
      @log = logger
    end

    def summarize(state)
      return FileReviewOutcome.with_no_findings(reviewed_path: nil) if state.reviewed_paths.empty?

      prompt = build_summary_prompt(state)
      response = @client.generate(prompt: prompt, schema: SUMMARY_SCHEMA, model: @model)
      summary_text = response["summary"].to_s.strip
      summary_text = "No summary produced." if summary_text.empty?
      @log.info { "summary produced" }
      FileReviewOutcome.new(findings: [], observation: summary_text, reviewed_path: nil)
    rescue Ollama::Error => e
      @log.warn { "summary failed: #{e.message}" }
      FileReviewOutcome.new(findings: [], observation: "Summary failed: #{e.message}", reviewed_path: nil)
    end

    private

    def build_summary_prompt(state)
      findings_text = format_findings(state.findings)
      <<~PROMPT
        Code review summary. Focus was: #{state.focus}
        Files reviewed: #{state.reviewed_paths.join(', ')}
        Findings:
        #{findings_text}

        Return JSON with one key "summary": a short paragraph for the developer (priorities, main risks, and one or two concrete next steps).
      PROMPT
    end

    def format_findings(findings)
      return "No findings." if findings.empty?

      findings.map do |f|
        "[#{f['severity']}] #{f['file']}#{f['line'] ? ":#{f['line']}" : ''} #{f['rule']}: #{f['message']}"
      end.join("\n")
    end
  end
end
