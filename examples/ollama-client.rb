# frozen_string_literal: true
# Example usage of the ollama-client gem: planner, thinking tests, context in chat,
# structured output, multi-turn. Run from repo root: bundle exec ruby examples/ollama-client.rb
# Override via env: OLLAMA_BASE_URL=http://localhost:11434

require "ollama_client"
require "json"
ENV["OLLAMA_MODEL"] = "llama3.1:8b-instruct-q4_K_M"
ENV["OLLAMA_TEMPERATURE"] = "0.5"
ENV["OLLAMA_TIMEOUT"] = "60"
BASE_URL = ENV.fetch("OLLAMA_BASE_URL", "http://192.168.1.4:11434")
OLLAMA_MODEL = ENV.fetch("OLLAMA_MODEL", "llama3.1:8b-instruct-q4_K_M")
OLLAMA_TEMPERATURE = ENV.fetch("OLLAMA_TEMPERATURE", 0.5)
OLLAMA_TIMEOUT = ENV.fetch("OLLAMA_TIMEOUT", 60)

def client_for(model:, temperature:, timeout:)
  config = Ollama::Config.new
  config.base_url = BASE_URL
  config.model = model
  config.temperature = temperature
  config.timeout = timeout
  config.retries = 2
  Ollama::Client.new(config: config)
end

model = ENV.fetch("OLLAMA_MODEL", "llama3.1:8b-instruct-q4_K_M") || "llama3.1:8b-instruct-q4_K_M" || "gemma3:4b"
temperature = ENV.fetch("OLLAMA_TEMPERATURE", 0.5) || 0.5
timeout = 60
client = client_for(model: model, temperature: temperature, timeout: timeout)

# ==================================================
# 1. PLANNER (thinking test) — break a constrained request into ordered steps
# ==================================================
planner = Ollama::Agent::Planner.new(client)
plan = planner.run(
  prompt: <<~PROMPT,
    Given the user request, output a JSON plan with ordered steps (title, description, action).
    Consider dependencies and constraints. Return ONLY valid JSON.
  PROMPT
  context: {
    user_request: "Ship a critical security fix. We have: 1 engineer for 2 days; code review takes 4 hours; staging deploy takes 1 hour; we must not skip tests. Break into steps with realistic order."
  }
)
puts plan

# Schema for plain-text reply via /api/generate
SIMPLE_RESPONSE_SCHEMA = { "type" => "object", "properties" => { "response" => { "type" => "string" } } }.freeze

def simple_query_via_generate(client, question, context: nil, model:)
  prompt = context ? "Context: #{context}\n\nQuestion: #{question}\n\nReply with a JSON object containing one key \"response\" and your answer as the value." : "Question: #{question}\n\nReply with a JSON object containing one key \"response\" and your answer as the value."
  out = client.generate(prompt: prompt, schema: SIMPLE_RESPONSE_SCHEMA, model: model)
  out["response"]
end

# ==================================================
# 2. THINKING TESTS — realistic reasoning prompts for model evaluation
# ==================================================
THINKING_PROMPT_PREFIX = "Reason step by step. State any assumptions, then give your conclusion. "

puts simple_query_via_generate(
  client,
  THINKING_PROMPT_PREFIX + "A team has 2 devs. Task A takes 2 days with 1 dev or 1 day with 2. Task B takes 1 day with 1 dev. We have exactly 2 days. What is the maximum number of tasks we can complete, and in what order? Answer in 2–3 sentences.",
  model: model
)
puts simple_query_via_generate(
  client,
  THINKING_PROMPT_PREFIX + "API latency went from 50ms to 2s right after we deployed. The only change was an update to the auth middleware. What is the most likely cause, and what would you check first? One short paragraph.",
  model: model
)
puts simple_query_via_generate(
  client,
  "We can ship a bugfix in 2 days without adding tests, or in 5 days with tests. When would you choose each option and why? Answer in 2–3 sentences.",
  model: model
)
puts simple_query_via_generate(
  client,
  THINKING_PROMPT_PREFIX + "We retry failed HTTP requests 3 times with exponential backoff. Under what real-world situation could this make things worse instead of better? One short paragraph.",
  model: model
)
puts simple_query_via_generate(
  client,
  "We have 2 hours before a board demo. Database is down, frontend has a visible bug, and slides are not ready. In what order would you tackle these and why? One short paragraph.",
  model: model
)
puts simple_query_via_generate(
  client,
  THINKING_PROMPT_PREFIX + "We just shipped a release and error rate went up 5%. List 2–3 possible causes, your assumptions, and whether you would roll back or not. One short paragraph.",
  model: model
)

thinking_schema = {
  "type" => "object",
  "required" => ["reasoning_steps", "conclusion"],
  "properties" => {
    "reasoning_steps" => { "type" => "array", "items" => { "type" => "string" }, "description" => "Step-by-step reasoning" },
    "conclusion" => { "type" => "string", "description" => "Final answer or recommendation" }
  }
}.freeze
thinking_prompt = <<~PROMPT
  We have a flaky test that fails about 10% of the time. It touches the database and the clock.
  Should we: (A) mock the DB and clock, (B) fix the test to be deterministic, (C) disable it and add a ticket.
  List your reasoning steps, then give your conclusion (A, B, or C) and one sentence why.
  Reply with JSON: {"reasoning_steps": ["...", "..."], "conclusion": "..."}.
PROMPT
begin
  thinking_out = client.generate(prompt: thinking_prompt, schema: thinking_schema, model: model)
  puts "Reasoning steps: #{thinking_out['reasoning_steps']&.join(' | ')}"
  puts "Conclusion: #{thinking_out['conclusion']}"
rescue Ollama::Error => e
  puts "Thinking schema test error: #{e.message}"
end

# ==================================================
# 3. CONTEXT IN CHAT — system message + user question
# ==================================================
context_info = "You are a support agent for a Billing API product. Be brief and professional. We offer 30-day refunds and live chat."
messages_with_context = [
  { role: "system", content: context_info },
  { role: "user", content: "Customer asked: 'Why was I charged twice?' How should we reply in 2–3 sentences?" }
]
response = client.chat_raw(model: model, messages: messages_with_context, allow_chat: true, options: { temperature: 0.7 })
puts response["message"]["content"]

def chat_with_context_helper(client, user_question, context: {}, model: "llama3.1:8b-instruct-q4_K_M")
  messages = []
  if context.any?
    context_str = context.map { |k, v| "#{k}: #{v}" }.join("\n")
    messages << { role: "system", content: "Context:\n#{context_str}" }
  end
  messages << { role: "user", content: user_question }
  client.chat_raw(model: model, messages: messages, allow_chat: true, options: { temperature: 0.7 })
end

context_data = { "Product" => "Billing API", "Plan" => "Enterprise", "Issue" => "Invoice export failing for date range" }
response = chat_with_context_helper(client, "Draft a short reply we can send to the customer acknowledging the issue and next steps.", context: context_data, model: model)
puts response["message"]["content"]

text_response_schema = { "type" => "object", "properties" => { "response" => { "type" => "string" } } }
def generate_with_context_and_schema(client, prompt, context: {}, schema:, model: "llama3.1:8b-instruct-q4_K_M")
  context_str = context.map { |k, v| "#{k}: #{v}" }.join("\n")
  full_prompt = "Context:\n#{context_str}\n\n#{prompt}\n\nReply with a JSON object with one key \"response\" and your answer as the value."
  client.generate(prompt: full_prompt, schema: schema, model: model)
end
begin
  structured_response = generate_with_context_and_schema(client, "Suggest one sentence we can use in an email subject line for a follow-up after a demo.", context: context_data, schema: text_response_schema, model: model)
  puts structured_response["response"]
rescue Ollama::Error => e
  puts "Error: #{e.message}"
end

# ==================================================
# 4. STRUCTURED OUTPUT (chat + schema) — extract ticket fields
# ==================================================
ticket_schema = {
  "type" => "object",
  "required" => ["tickets"],
  "properties" => {
    "tickets" => {
      "type" => "array",
      "items" => {
        "type" => "object",
        "required" => ["customer_email", "summary", "priority"],
        "properties" => {
          "customer_email" => { "type" => "string" },
          "summary" => { "type" => "string" },
          "priority" => { "type" => "string", "enum" => ["low", "medium", "high"] }
        }
      }
    }
  }
}
messages = [
  { role: "system", content: "You extract support ticket info from user messages. Return valid JSON only." },
  { role: "user", content: "From this message extract one ticket: 'Hi, I'm sarah@acme.com. Our dashboard has been down for 2 hours and we have a launch today. Need help ASAP.'" }
]
begin
  response = client.chat(model: model, messages: messages, format: ticket_schema, allow_chat: true, options: { temperature: 0 })
  response["tickets"].each { |t| puts "#{t['customer_email']} — #{t['summary']} [#{t['priority']}]" }
rescue Ollama::SchemaViolationError => e
  puts "Schema violation: #{e.message}"
rescue Ollama::Error => e
  puts "Error: #{e.message}"
end

# ==================================================
# 5. MULTI-TURN (conversation history)
# ==================================================
conversation_with_context = [
  { role: "user", content: "I want a refund for my subscription." },
  { role: "assistant", content: "I can help with that. Could you share the email on the account and when you subscribed?" },
  { role: "user", content: "What if I'm past 30 days?" }
]
begin
  response_with_history = client.chat_raw(model: model, messages: conversation_with_context, allow_chat: true, options: { temperature: 0.7 })
  puts "Follow-up reply: #{response_with_history['message']['content']}"
rescue Ollama::Error => e
  puts "Error: #{e.message}"
end

# ==================================================
# 6. REUSABLE CONTEXT HELPER
# ==================================================
def chat_with_context(client, user_message, context: {}, conversation_history: [], model_name: "llama3.1:8b-instruct-q4_K_M")
  messages = []
  if context.any?
    context_str = context.map { |k, v| "#{k}: #{v}" }.join("\n")
    messages << { role: "system", content: "Context:\n#{context_str}" }
  end
  messages.concat(conversation_history)
  messages << { role: "user", content: user_message }
  client.chat_raw(model: model_name, messages: messages, allow_chat: true, options: { temperature: 0.7 })
end
context = { "Product" => "Analytics API", "Customer usage" => "High API calls, low storage", "Current plan" => "Pro" }
begin
  response = chat_with_context(client, "Which upgrade tier should we suggest and why in one sentence?", context: context, model_name: model)
  puts response["message"]["content"]
rescue Ollama::Error => e
  puts "Error: #{e.message}"
end
