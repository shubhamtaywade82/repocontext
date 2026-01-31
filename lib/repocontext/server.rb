# frozen_string_literal: true

require "sinatra/base"
require "json"
require "webrick"
require_relative "../repocontext"
require_relative "vector_store"


module RepoContext
  class Server < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :views, File.join(File.expand_path("../..", __dir__), "views")
    set :public_folder, File.join(File.expand_path("../..", __dir__), "public")

    def self.build_ollama_client
      RepoContext::OllamaClientFactory.build(
        model: RepoContext::Settings::OLLAMA_MODEL,
        temperature: RepoContext::Settings::OLLAMA_TEMPERATURE.to_f,
        timeout: RepoContext::Settings::OLLAMA_TIMEOUT
      )
    end

    def self.log_server_start
      RepoContext::Settings.logger.info do
        "Server initialized: context_path=#{RepoContext::Settings::REPO_ROOT}, " \
        "model=#{RepoContext::Settings::OLLAMA_MODEL}"
      end
    end

    configure do
      set :ollama_client, build_ollama_client
      set :ollama_model, RepoContext::Settings::OLLAMA_MODEL
      log_server_start
    rescue StandardError => e
      RepoContext::Settings.logger.error { "Failed to initialize Ollama client: #{e.message}" }
      raise
    end

    helpers do
      def log
        RepoContext::Settings.logger
      end

      def ollama_client
        settings.ollama_client
      end

      def discovery_path_selector
        @discovery_path_selector ||= RepoContext::DiscoveryPathSelector.new(
          repo_root: RepoContext::Settings::REPO_ROOT,
          client: ollama_client,
          model: settings.ollama_model,
          logger: log
        )
      end

      def embedding_context_builder
        @embedding_context_builder ||= RepoContext::EmbeddingContextBuilder.new(
          client: ollama_client,
          repo_root: RepoContext::Settings::REPO_ROOT,
          candidate_paths_source: -> { discovery_path_selector.candidate_paths },
          logger: log
        )
      end

      def repo_context_builder
        @repo_context_builder ||= RepoContext::ContextBuilder.new(
          discovery_selector: discovery_path_selector,
          embedding_builder: embedding_context_builder,
          logger: log
        )
      end

      def repo_chat_service
        @repo_chat_service ||= RepoContext::ChatService.new(
          client: ollama_client,
          model: settings.ollama_model,
          logger: log
        )
      end

      def code_review_agent
        @code_review_agent ||= RepoContext::CodeReviewAgent.new(
          path_source: discovery_path_selector,
          planner: RepoContext::ReviewPlanner.new(
            client: ollama_client,
            model: settings.ollama_model,
            logger: log
          ),
          executor: RepoContext::ReviewStepExecutor.new(
            client: ollama_client,
            model: RepoContext::Settings::OLLAMA_CODE_MODEL,
            logger: log
          ),
          summary_writer: RepoContext::ReviewSummaryWriter.new(
            client: ollama_client,
            model: settings.ollama_model,
            logger: log
          ),
          logger: log
        )
      end

      def chat_request_handler
        @chat_request_handler ||= RepoContext::ChatRequestHandler.new(
          context_builder: repo_context_builder,
          chat_service: repo_chat_service,
          logger: log
        )
      end

      def review_request_handler
        @review_request_handler ||= RepoContext::ReviewRequestHandler.new(
          review_agent: code_review_agent,
          logger: log
        )
      end

      def stream_event_line(event_name, event_data = {})
        payload = { event: event_name }.merge(event_data)
        "#{payload.to_json}\n"
      end

      def write_stream_event(stream_yielder, event_name, event_data = {})
        stream_yielder << stream_event_line(event_name, event_data)
        stream_yielder.flush if stream_yielder.respond_to?(:flush)
      end

      def append_exchange_to_history(history, user_msg, assistant_msg)
        history + [
          { "role" => "user", "content" => user_msg },
          { "role" => "assistant", "content" => assistant_msg }
        ]
      end

      def parse_chat_request
        request_body = read_and_parse_json_body
        user_message = extract_user_message(request_body)
        message_history = extract_message_history(request_body)
        model = extract_model(request_body)
        log.info { "api/chat: request (history=#{message_history.size}, model=#{model})" }
        [user_message, message_history, model]
      end

      def read_and_parse_json_body
        request.body.rewind
        JSON.parse(request.body.read)
      end

      def extract_user_message(request_body)
        request_body["message"].to_s.strip
      end

      def extract_message_history(request_body)
        history = request_body["history"]
        history.is_a?(Array) ? history : []
      end

      def extract_model(request_body)
        model = request_body["model"].to_s.strip
        model.empty? ? Settings::OLLAMA_MODEL : model
      end

      def parse_review_request
        request_body = read_and_parse_json_body
        review_paths = extract_review_paths(request_body)
        review_focus = extract_review_focus(request_body)
        model = extract_model(request_body)
        [review_paths, review_focus, model]
      end

      def extract_review_paths(request_body)
        paths = request_body["paths"]
        return [] unless paths.is_a?(Array)

        paths.map(&:to_s).reject(&:empty?)
      end

      def extract_review_focus(request_body)
        focus = request_body["focus"].to_s.strip
        focus.empty? ? RepoContext::Settings::REVIEW_FOCUS : focus
      end

      def log_and_respond_ollama_error(error)
        log.error { "Ollama error: #{error.message}" }
        status 502
        content_type :json
        { error: "Ollama error: #{error.message}" }.to_json
      end

      def log_and_respond_internal_error(error)
        log.error { "Internal error: #{error.class} - #{error.message}" }
        log.error { error.backtrace&.first(5)&.join("\n") }
        status 500
        content_type :json
        { error: "Internal server error" }.to_json
      end

      def json_error_response(status_code, error_message)
        status status_code
        content_type :json
        { error: error_message }.to_json
      end

      def build_chat_stream_enumerator(user_message, message_history, out)
        on_progress = ->(msg) { write_stream_event(out, "status", message: msg) }
        result = chat_request_handler.call(
          message: user_message,
          message_history: message_history,
          &on_progress
        )
        write_stream_event(out, "done", response: result[:response], history: result[:history])
      rescue Ollama::Error => e
        log.error { "Ollama error: #{e.message}" }
        write_stream_event(out, "error", error: "Ollama error: #{e.message}")
      rescue StandardError => e
        log.error { "Chat stream error: #{e.class} - #{e.message}" }
        write_stream_event(out, "error", error: "Internal server error")
      end

      def build_review_stream_enumerator(review_paths, review_focus, out)
        write_stream_event(out, "status", message: "Starting code review…")
        code_review_agent.run_with_events(request_paths: review_paths, focus: review_focus) do |event_name, iteration, payload|
          emit_review_stream_event(out, event_name, iteration, payload)
        end
      rescue Ollama::Error => e
        log.error { "Ollama error: #{e.message}" }
        write_stream_event(out, "error", error: "Ollama error: #{e.message}")
      rescue StandardError => e
        log.error { "Review stream error: #{e.class} - #{e.message}" }
        write_stream_event(out, "error", error: "Internal server error")
      end

      def emit_review_stream_event(out, event_name, iteration, payload)
        case event_name
        when :init
          write_stream_event(out, "init", paths: payload[:paths])
        when :plan
          write_stream_event(out, "status", message: "Planning step #{iteration + 1}…")
        when :review_file
          write_stream_event(out, "review_file", path: payload)
        when :review_done
          write_stream_event(out, "findings", findings: payload.findings, path: payload.reviewed_path)
        when :summarize
          write_stream_event(out, "status", message: "Summarizing…")
        when :summary_done
          write_stream_event(out, "summary", summary: payload.observation)
        when :done
          write_stream_event(out, "done",
            findings: payload.findings,
            summary: payload.observations.last,
            reviewed_paths: payload.reviewed_paths,
            iterations: payload.iteration)
        end
      end

      def suggested_questions
        questions = [
          "Summarize this repository",
          "Identify potential technical debt",
          "Explain the architecture"
        ]

        # Context-aware inclusions
        if File.exist?(File.join(settings.root, "Gemfile"))
          questions << "Explain the dependencies in Gemfile"
        end

        if Dir.exist?(File.join(settings.root, "spec")) || Dir.exist?(File.join(settings.root, "test"))
          questions << "How do I run the tests?"
        end

        questions.uniq
      end
    end

    get "/" do
      log.debug { "GET /" }
      erb :index
    end

    get "/api/models" do
      content_type :json
      begin
        # Fetch models from Ollama - returns array of model names
        model_names = ollama_client.list_models

        # Filter out embedding models and format for UI
        models = model_names
          .reject { |name| name.include?("embed") }  # Skip embedding models
          .map do |name|
            {
              name: name,
              display_name: format_model_display_name(name)
            }
          end

        { models: models }.to_json
      rescue StandardError => e
        log.error { "Failed to fetch models: #{e.message}" }
        # Fallback to default models if Ollama is unavailable
        { models: [
          { name: Settings::OLLAMA_MODEL, display_name: "Default Model" }
        ] }.to_json
      end
    end

    private

    def format_model_display_name(model_name)
      # Parse "llama3.1:8b-instruct-q4_K_M" into readable name
      parts = model_name.split(':')
      base = parts[0]
      variant = parts[1] || ""

      # Capitalize base name (llama3.1 -> Llama 3.1)
      display_base = base.gsub(/(\d+)\.(\d+)/, '\1.\2')
                         .gsub(/(\D)(\d)/, '\1 \2')
                         .split(/[-_\.]/)
                         .map(&:capitalize)
                         .join(' ')

      # Parse variant for size and type
      if variant.include?("instruct")
        type = "Instruct"
      elsif variant.include?("coder")
        type = "Coder"
      else
        type = "Base"
      end

      # Extract size (8b, 7b, etc.)
      size_match = variant.match(/(\d+)b/)
      size = size_match ? size_match[1] + "B" : ""

      # Build display name
      parts = [display_base, size, type].reject(&:empty?)
      parts.join(' ')
    end

    public

    post "/api/chat" do
      user_message, message_history, model = parse_chat_request
      return json_error_response(422, "message is required") if user_message.empty?

      chat_service = RepoContext::ChatService.new(
        client: ollama_client,
        model: model,
        logger: log
      )

      codebase_context = repo_context_builder.gather(user_message)
      reply_text = chat_service.ask(
        user_message,
        repo_context: codebase_context,
        conversation_history: message_history
      )
      updated_history = append_exchange_to_history(message_history, user_message, reply_text)
      content_type :json
      { response: reply_text, history: updated_history }.to_json
    rescue Ollama::Error => e
      return log_and_respond_ollama_error(e)
    rescue JSON::ParserError => e
      log.warn { "Invalid JSON body: #{e.message}" }
      return json_error_response(422, "Invalid JSON body")
    rescue StandardError => e
      return log_and_respond_internal_error(e)
    end

    post "/api/chat/stream" do
      user_message, message_history, model = parse_chat_request
      return json_error_response(422, "message is required") if user_message.empty?

      content_type "application/x-ndjson", charset: "utf-8"
      stream do |out|
        on_progress = ->(msg) { write_stream_event(out, "status", message: msg) }

        on_progress.call("Initializing...")
        codebase_context = repo_context_builder.gather(user_message, &on_progress)

        chat_service = RepoContext::ChatService.new(
          client: ollama_client,
          model: model,
          logger: log
        )

        reply_text = chat_service.ask(
          user_message,
          repo_context: codebase_context,
          conversation_history: message_history,
          &on_progress
        )
        updated_history = append_exchange_to_history(message_history, user_message, reply_text)
        write_stream_event(out, "done", response: reply_text, history: updated_history)
      rescue Ollama::Error => e
        log.error { "Ollama error: #{e.message}" }
        write_stream_event(out, "error", error: "Ollama error: #{e.message}")
      end
    rescue JSON::ParserError
      json_error_response(422, "Invalid JSON body")
    rescue StandardError => e
      log_and_respond_internal_error(e)
    end

    post "/api/review" do
      review_paths, review_focus = parse_review_request
      log.info { "api/review: paths=#{review_paths.size}, focus=#{review_focus[0, RepoContext::Settings::LOG_FOCUS_MAX_CHARS]}..." }

      result = review_request_handler.call(paths: review_paths, focus: review_focus)
      content_type :json
      result.to_json
    rescue Ollama::Error => e
      return log_and_respond_ollama_error(e)
    rescue JSON::ParserError => e
      log.warn { "Invalid JSON body: #{e.message}" }
      return json_error_response(422, "Invalid JSON body")
    rescue StandardError => e
      return log_and_respond_internal_error(e)
    end

    post "/api/review/stream" do
      review_paths, review_focus, model = parse_review_request
      content_type "application/x-ndjson", charset: "utf-8"
      stream do |out|
        write_stream_event(out, "status", message: "Starting code review…")

        # Create code review agent with selected model
        review_agent = RepoContext::CodeReviewAgent.new(
          path_source: discovery_path_selector,
          planner: RepoContext::ReviewPlanner.new(
            client: ollama_client,
            model: model,
            logger: log
          ),
          executor: RepoContext::ReviewStepExecutor.new(
            client: ollama_client,
            model: model,
            logger: log
          ),
          summary_writer: RepoContext::ReviewSummaryWriter.new(
            client: ollama_client,
            model: model,
            logger: log
          ),
          logger: log
        )

        review_agent.run_with_events(request_paths: review_paths, focus: review_focus) do |event_name, iteration, payload|
          emit_review_stream_event(out, event_name, iteration, payload)
        end
      rescue Ollama::Error => e
        log.error { "Ollama error: #{e.message}" }
        write_stream_event(out, "error", error: "Ollama error: #{e.message}")
      end
    rescue JSON::ParserError
      json_error_response(422, "Invalid JSON body")
    rescue StandardError => e
      log_and_respond_internal_error(e)
    end
  end
end
