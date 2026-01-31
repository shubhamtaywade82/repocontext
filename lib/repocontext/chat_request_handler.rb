# frozen_string_literal: true

module RepoContext
  # Single responsibility: run the chat flow (gather context, ask LLM, return reply and history).
  # Depends on context_builder and chat_service; accepts optional progress callback.
  class ChatRequestHandler
    def initialize(context_builder:, chat_service:, logger: Settings.logger)
      @context_builder = context_builder
      @chat_service = chat_service
      @log = logger
    end

    def call(message:, message_history:, &on_progress)
      context = @context_builder.gather(message, &on_progress)
      reply = @chat_service.ask(
        message,
        repo_context: context,
        conversation_history: message_history,
        &on_progress
      )
      history = message_history + [
        { "role" => "user", "content" => message },
        { "role" => "assistant", "content" => reply }
      ]
      { response: reply, history: history }
    end
  end
end
