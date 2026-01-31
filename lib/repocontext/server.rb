# frozen_string_literal: true

require "sinatra/base"
require "json"
require "webrick"
require_relative "../repocontext"

module RepoContext
  class Server < Sinatra::Base
    set :root, File.expand_path("../..", __dir__)
    set :views, File.join(File.expand_path("../..", __dir__), "views")
    set :public_folder, File.join(File.expand_path("../..", __dir__), "public") # If any public assets exist

    configure do
      begin
        set :ollama_client, RepoContext::OllamaClientFactory.build(
          model: RepoContext::Settings::OLLAMA_MODEL,
          temperature: RepoContext::Settings::OLLAMA_TEMPERATURE.to_f,
          timeout: RepoContext::Settings::OLLAMA_TIMEOUT
        )
        set :ollama_model, RepoContext::Settings::OLLAMA_MODEL
        RepoContext::Settings.logger.info do
          "Server initialized: context_path=#{RepoContext::Settings::REPO_ROOT}, " \
          "model=#{RepoContext::Settings::OLLAMA_MODEL}"
        end
      rescue StandardError => e
        RepoContext::Settings.logger.error { "Failed to initialize Ollama client: #{e.message}" }
      end
    end

    helpers do
      def ollama_client
        settings.ollama_client
      end

      def discovery_path_selector
        @discovery_path_selector ||= RepoContext::DiscoveryPathSelector.new(
          repo_root: RepoContext::Settings::REPO_ROOT,
          client: ollama_client,
          model: settings.ollama_model,
          logger: RepoContext::Settings.logger
        )
      end

      def embedding_context_builder
        @embedding_context_builder ||= RepoContext::EmbeddingContextBuilder.new(
          client: ollama_client,
          repo_root: RepoContext::Settings::REPO_ROOT,
          candidate_paths_source: -> { discovery_path_selector.candidate_paths },
          logger: RepoContext::Settings.logger
        )
      end

      def repo_context_builder
        @repo_context_builder ||= RepoContext::ContextBuilder.new(
          discovery_selector: discovery_path_selector,
          embedding_builder: embedding_context_builder,
          logger: RepoContext::Settings.logger
        )
      end

      def repo_chat_service
        @repo_chat_service ||= RepoContext::ChatService.new(
          client: ollama_client,
          model: settings.ollama_model,
          logger: RepoContext::Settings.logger
        )
      end

      def code_review_agent
        @code_review_agent ||= RepoContext::CodeReviewAgent.new(
          path_source: discovery_path_selector,
          planner: RepoContext::ReviewPlanner.new(
            client: ollama_client,
            model: settings.ollama_model,
            logger: RepoContext::Settings.logger
          ),
          executor: RepoContext::ReviewStepExecutor.new(
            client: ollama_client,
            model: RepoContext::Settings::OLLAMA_CODE_MODEL,
            logger: RepoContext::Settings.logger
          ),
          summary_writer: RepoContext::ReviewSummaryWriter.new(
            client: ollama_client,
            model: settings.ollama_model,
            logger: RepoContext::Settings.logger
          ),
          logger: RepoContext::Settings.logger
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

      def parse_chat_request
        request_body = read_and_parse_json_body
        user_message = extract_user_message(request_body)
        message_history = extract_message_history(request_body)
        RepoContext::Settings.logger.info { "api/chat: request (history=#{message_history.size})" }
        [user_message, message_history]
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

      def parse_review_request
        request_body = read_and_parse_json_body
        review_paths = extract_review_paths(request_body)
        review_focus = extract_review_focus(request_body)
        [review_paths, review_focus]
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
        RepoContext::Settings.logger.error { "Ollama error: #{error.message}" }
        status 502
        content_type :json
        { error: "Ollama error: #{error.message}" }.to_json
      end

      def json_error_response(status_code, error_message)
        status status_code
        content_type :json
        { error: error_message }.to_json
      end

      def build_chat_stream_enumerator(user_message, message_history, out)
        write_stream_event(out, "status", message: "Gathering context…")
        codebase_context = repo_context_builder.gather(user_message)
        write_stream_event(out, "status", message: "Asking Ollama…")
        reply_text = repo_chat_service.ask(
          user_message,
          repo_context: codebase_context,
          conversation_history: message_history
        )
        updated_history = append_exchange_to_history(message_history, user_message, reply_text)
        write_stream_event(out, "done", response: reply_text, history: updated_history)
      rescue Ollama::Error => e
        RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
        write_stream_event(out, "error", error: "Ollama error: #{e.message}")
      end

      def append_exchange_to_history(message_history, user_message, reply_text)
        message_history + [
          { "role" => "user", "content" => user_message },
          { "role" => "assistant", "content" => reply_text }
        ]
      end

      def build_review_stream_enumerator(review_paths, review_focus, out)
        write_stream_event(out, "status", message: "Starting code review…")
        code_review_agent.run_with_events(request_paths: review_paths, focus: review_focus) do |event_name, iteration, payload|
          emit_review_stream_event(out, event_name, iteration, payload)
        end
      rescue Ollama::Error => e
        RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
        write_stream_event(out, "error", error: "Ollama error: #{e.message}")
      end

      def emit_review_stream_event(out, event_name, iteration, payload)
        case event_name
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
    end

    get "/" do
      RepoContext::Settings.logger.debug { "GET /" }
      erb :index
    end

    post "/api/chat" do
      user_message, message_history = parse_chat_request
      return json_error_response(422, "message is required") if user_message.empty?

      codebase_context = repo_context_builder.gather(user_message)
      reply_text = repo_chat_service.ask(
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
      RepoContext::Settings.logger.warn { "Invalid JSON body: #{e.message}" }
      return json_error_response(422, "Invalid JSON body")
    end

    post "/api/chat/stream" do
      user_message, message_history = parse_chat_request
      return json_error_response(422, "message is required") if user_message.empty?

      content_type "application/x-ndjson", charset: "utf-8"
      stream do |out|
        build_chat_stream_enumerator(user_message, message_history, out)
      end
    rescue JSON::ParserError
      json_error_response(422, "Invalid JSON body")
    end

    post "/api/review" do
      review_paths, review_focus = parse_review_request
      RepoContext::Settings.logger.info { "api/review: paths=#{review_paths.size}, focus=#{review_focus[0, 60]}..." }

      review_result_state = code_review_agent.run(request_paths: review_paths, focus: review_focus)
      content_type :json
      {
        findings: review_result_state.findings,
        summary: review_result_state.observations.last,
        reviewed_paths: review_result_state.reviewed_paths,
        iterations: review_result_state.iteration
      }.to_json
    rescue Ollama::Error => e
      return log_and_respond_ollama_error(e)
    rescue JSON::ParserError => e
      RepoContext::Settings.logger.warn { "Invalid JSON body: #{e.message}" }
      return json_error_response(422, "Invalid JSON body")
    end

    post "/api/review/stream" do
      review_paths, review_focus = parse_review_request
      body = Enumerator.new do |yielder|
        build_review_stream_enumerator(review_paths, review_focus, yielder)
      end
      [200, { "Content-Type" => "application/x-ndjson; charset=utf-8" }, body]
    rescue JSON::ParserError
      json_error_response(422, "Invalid JSON body")
    end
  end
end
