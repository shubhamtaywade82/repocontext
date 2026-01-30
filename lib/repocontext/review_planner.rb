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
      @ollama_client = client
      @model_name = model
      @log = logger
    end

    def next_step(review_state, candidate_paths)
      return done_step("No files to review") if candidate_paths.empty?

      paths_not_yet_reviewed = review_state.remaining_candidates(candidate_paths)
      return done_step("All candidates reviewed") if paths_not_yet_reviewed.empty?

      llm_response = request_next_action(review_state, paths_not_yet_reviewed)
      build_plan_step_from_response(llm_response, paths_not_yet_reviewed)
    rescue Ollama::Error => e
      @log.warn { "planner failed: #{e.message}, defaulting to first remaining file" }
      ReviewPlanStep.new(action: ReviewPlanStep::REVIEW_FILE, target: paths_not_yet_reviewed.first, reasoning: "fallback")
    end

    private

    def done_step(reasoning)
      ReviewPlanStep.new(action: ReviewPlanStep::DONE, reasoning: reasoning)
    end

    def request_next_action(review_state, paths_not_yet_reviewed)
      plan_prompt = build_plan_prompt(review_state, paths_not_yet_reviewed)
      @ollama_client.generate(prompt: plan_prompt, schema: PLAN_SCHEMA, model: @model_name)
    end

    def build_plan_step_from_response(llm_response, paths_not_yet_reviewed)
      action = parse_action_from_response(llm_response)
      target = parse_target_from_response(llm_response)
      reasoning = llm_response["reasoning"].to_s.strip
      @log.info { "planner: action=#{action}, target=#{target}" }
      ReviewPlanStep.new(action: action, target: target, reasoning: reasoning)
    end

    def parse_action_from_response(llm_response)
      return ReviewPlanStep::DONE if llm_response["done"] == true

      llm_response["next_action"].to_s.strip
    end

    def parse_target_from_response(llm_response)
      target = llm_response["target"].to_s.strip
      target.empty? ? nil : target
    end

    def build_plan_prompt(review_state, paths_not_yet_reviewed)
      <<~PROMPT
        You are planning the next step of a code review. Review focus: #{review_state.focus}

        #{review_state.summary_for_planner}

        Remaining files not yet reviewed (choose one path exactly as listed, or say summarize/done):
        #{paths_not_yet_reviewed.first(40).join("\n")}

        If there are remaining files, set next_action to "review_file" and target to one path from the list. When no files remain or you are done, set next_action to "done" and done to true.
        Return JSON: done (boolean), next_action ("review_file" | "summarize" | "done"), target (path when review_file), reasoning (short).
      PROMPT
    end
  end
end
