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
      return done_step("No files to review") if candidate_paths.empty?

      remaining_paths = state.remaining_candidates(candidate_paths)
      return done_step("All candidates reviewed") if remaining_paths.empty?

      plan_response = request_next_action(state, remaining_paths)
      build_plan_step(plan_response, remaining_paths)
    rescue Ollama::Error => e
      @log.warn { "planner failed: #{e.message}, defaulting to first remaining file" }
      ReviewPlanStep.new(action: ReviewPlanStep::REVIEW_FILE, target: remaining_paths.first, reasoning: "fallback")
    end

    private

    def done_step(reasoning)
      ReviewPlanStep.new(action: ReviewPlanStep::DONE, reasoning: reasoning)
    end

    def request_next_action(state, remaining_paths)
      prompt = build_plan_prompt(state, remaining_paths)
      @client.generate(prompt: prompt, schema: PLAN_SCHEMA, model: @model)
    end

    def build_plan_step(plan_response, remaining_paths)
      action = plan_response["next_action"].to_s.strip
      action = ReviewPlanStep::DONE if plan_response["done"] == true
      target = plan_response["target"].to_s.strip
      target = nil if target.empty?
      @log.info { "planner: action=#{action}, target=#{target}" }
      ReviewPlanStep.new(action: action, target: target, reasoning: plan_response["reasoning"].to_s.strip)
    end

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
