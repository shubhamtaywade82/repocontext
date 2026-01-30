# frozen_string_literal: true

module RepoContext
  class ChatService
    SIMPLE_RESPONSE_SCHEMA = { "type" => "object", "properties" => { "response" => { "type" => "string" } } }.freeze

    def initialize(client:, model:, logger: Settings.logger)
      @ollama_client = client
      @model_name = model
      @log = logger
      @temperature = Settings::OLLAMA_TEMPERATURE.to_f
    end

    def ask(question, repo_context:, conversation_history:)
      @log.info { "ask (chat): \"#{question[0, 80]}#{question.size > 80 ? '...' : ''}\" (model=#{@model_name})" }
      response_text = send_chat_request(repo_context, conversation_history, question)
      @log.info { "reply: #{response_text.size} chars" }
      response_text
    rescue Ollama::Error => e
      @log.warn { "chat_raw failed: #{e.message}, falling back to generate" }
      ask_via_generate(question, repo_context: repo_context)
    end

    def ask_via_generate(question, repo_context:)
      prompt = build_generate_prompt(repo_context, question)
      generate_response = @ollama_client.generate(prompt: prompt, schema: SIMPLE_RESPONSE_SCHEMA, model: @model_name)
      generate_response["response"].to_s
    end

    private

    def send_chat_request(repo_context, conversation_history, question)
      messages = build_messages(repo_context, conversation_history, question)
      chat_response = @ollama_client.chat_raw(
        model: @model_name,
        messages: messages,
        allow_chat: true,
        options: { temperature: @temperature }
      )
      chat_response.dig("message", "content").to_s
    end

    def system_content(repo_context)
      <<~SYSTEM.strip
        You are a helpful assistant for a codebase. The user is asking about the repository whose file contents are provided below. "This", "this repo", "the codebase", "in this", "available in this", and similar phrases always refer to that content—do not ask for clarification or a URL. Answer from the provided code and file contents. Section headers "--- path ---" show which files are included; if the user asks what files are available, list those paths. When the user asks what a ticket, task, or phrase means (e.g. "what does this ticket mean X"), infer from the codebase what it could mean—use the repo's structure, CI/CD, config, and docs—and say you're inferring from the context. Only say "not in the provided file contents" if you truly cannot relate the question to the context. Be concise but accurate.

        Codebase context (file contents from the repo):
        #{repo_context}
      SYSTEM
    end

    def build_messages(repo_context, conversation_history, question)
      messages = [{ role: "system", content: system_content(repo_context) }]
      conversation_history.each do |msg|
        role = msg["role"].to_s == "assistant" ? "assistant" : "user"
        content = msg["content"].to_s
        messages << { role: role, content: content } if content.strip != ""
      end
      messages << { role: "user", content: question }
      messages
    end

    def build_generate_prompt(repo_context, question)
      <<~PROMPT
        You are a helpful assistant for a codebase. The user is asking about the repository whose file contents are provided below. "This", "in this", "available in this" refer to that content—answer from it; do not ask for clarification or a URL. Section headers "--- path ---" show which files are included; if asked what files are available, list those paths. When the user asks what a ticket or phrase means (e.g. "what does this ticket mean X"), infer from the codebase what it could mean using the repo's structure, CI/CD, config, and docs; say you're inferring from the context. Only say "not in the provided file contents" if you cannot relate the question to the context.

        Codebase context (file contents from the repo):
        #{repo_context}

        Question: #{question}

        Reply with a JSON object containing one key "response" and your answer as the value. Be concise but accurate.
      PROMPT
    end
  end
end
