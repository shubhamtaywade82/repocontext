# frozen_string_literal: true

module RepoContext
  # Plans the next step of a code review by asking the LLM which file to review or whether to stop.
  # Interface: #next_step(review_state, candidate_paths) => ReviewPlanStep.
  # Dependencies: client (LLM duck type: #generate(prompt:, schema:, model:)), model (string), logger.
  class ReviewPlanner
    PLAN_PATHS_LIMIT = 40

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

    PlanResponse = Struct.new(:done, :next_action, :target, :reasoning, keyword_init: true)

    def initialize(client:, model:, logger: Settings.logger)
      @ollama_client = client
      @model_name = model
      @log = logger
    end

    def next_step(review_state, candidate_paths)
      return done_step("No files to review") if candidate_paths.empty?

      paths_not_yet_reviewed = review_state.remaining_candidates(candidate_paths)
      return done_step("All candidates reviewed") if paths_not_yet_reviewed.empty?

      raw = request_next_action(review_state, paths_not_yet_reviewed)
      parsed = parse_plan_response(raw)
      build_plan_step(parsed)
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

    def parse_plan_response(raw)
      return PlanResponse.new(done: true, next_action: ReviewPlanStep::DONE, target: nil, reasoning: "") unless raw.is_a?(Hash)

      target_str = raw["target"].to_s.strip
      PlanResponse.new(
        done: raw["done"] == true,
        next_action: raw["next_action"].to_s.strip,
        target: target_str.empty? ? nil : target_str,
        reasoning: raw["reasoning"].to_s.strip
      )
    end

    def build_plan_step(parsed)
      action = parsed.done ? ReviewPlanStep::DONE : (parsed.next_action.to_s.strip.empty? ? ReviewPlanStep::DONE : parsed.next_action)
      @log.info { "planner: action=#{action}, target=#{parsed.target}" }
      ReviewPlanStep.new(action: action, target: parsed.target, reasoning: parsed.reasoning)
    end

    def build_plan_prompt(review_state, paths_not_yet_reviewed)
      path_list = paths_not_yet_reviewed.first(PLAN_PATHS_LIMIT).join("\n")
      <<~PROMPT
        You are planning the next step of a code review. Review focus: #{review_state.focus}

        #{review_state.summary_for_planner}

        Remaining files not yet reviewed (choose one path exactly as listed, or say summarize/done):
        #{path_list}

        If there are remaining files, set next_action to "review_file" and target to one path from the list. When no files remain or you are done, set next_action to "done" and done to true.
        Return JSON: done (boolean), next_action ("review_file" | "summarize" | "done"), target (path when review_file), reasoning (short).
      PROMPT
    end
  end
end
