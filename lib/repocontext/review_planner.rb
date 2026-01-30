# frozen_string_literal: true

module RepoContext
  class ReviewPlanner
    PLAN_SCHEMA = {
      "type" => "object",
      "required" => %w[done next_action],
      "properties" => {
        "done" => { "type" => "boolean", "description" => "True when review is complete" },
        "next_action" => {
          "type" => "string",
          "enum" => %w[review_file summarize done],
          "description" => "What to do next"
        },
        "target" => { "type" => "string", "description" => "File path when next_action is review_file" },
        "reasoning" => { "type" => "string", "description" => "Brief reason for this choice" }
      }
    }.freeze

    def initialize(client:, model:, logger: Settings.logger)
      @client = client
      @model = model
      @log = logger
    end

    def next_step(state, candidate_paths)
      return ReviewPlanStep.new(action: ReviewPlanStep::DONE, reasoning: "No files to review") if candidate_paths.empty?

      remaining = state.remaining_candidates(candidate_paths).to_a
      return ReviewPlanStep.new(action: ReviewPlanStep::DONE, reasoning: "All candidates reviewed") if remaining.empty?

      prompt = build_plan_prompt(state, remaining)
      out = @client.generate(prompt: prompt, schema: PLAN_SCHEMA, model: @model)
      action = out["next_action"].to_s.strip
      action = ReviewPlanStep::DONE if out["done"] == true
      target = out["target"].to_s.strip
      target = nil if target.empty?
      @log.info { "planner: action=#{action}, target=#{target}" }
      ReviewPlanStep.new(action: action, target: target, reasoning: out["reasoning"].to_s.strip)
    rescue Ollama::Error => e
      @log.warn { "planner failed: #{e.message}, defaulting to first remaining file" }
      ReviewPlanStep.new(action: ReviewPlanStep::REVIEW_FILE, target: remaining.first, reasoning: "fallback")
    end

    private

    def build_plan_prompt(state, remaining_paths)
      <<~PROMPT
        You are planning the next step of a code review. Review focus: #{state.focus}

        #{state.summary_for_planner}

        Remaining files not yet reviewed (choose one path exactly as listed, or say summarize/done):
        #{remaining_paths.first(40).join("\n")}

        If there are remaining files, set next_action to "review_file" and target to one path from the list. When no files remain or you are done, set next_action to "done" and done to true.
        Return JSON: done (boolean), next_action ("review_file" | "summarize" | "done"), target (path when review_file), reasoning (short).
      PROMPT
    end
  end
end
