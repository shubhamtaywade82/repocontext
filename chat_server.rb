# frozen_string_literal: true
# Run: bundle exec ruby chat_server.rb  then open http://localhost:<PORT>
# PORT=4568 to use a different port. LOG_LEVEL=debug for more detail.
# Context: REPO_CONTEXT_PATH, CONTEXT_FILES, CONTEXT_MAX_CHARS, DISCOVERY_AGENT_ENABLED.
# Embeddings: EMBED_CONTEXT_ENABLED=true, OLLAMA_EMBED_MODEL=nomic-embed-text (ollama pull nomic-embed-text).

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "webrick"
require "json"
require "sinatra"
require "repocontext"

set :port, ENV.fetch("PORT", 4567).to_i
set :views, File.join(__dir__, "views")

def client
  settings.ollama_client
end

def context_builder
  @context_builder ||= RepoContext::ContextBuilder.new(
    client: client,
    model: settings.ollama_model,
    logger: RepoContext::Settings.logger
  )
end

def chat_service
  @chat_service ||= RepoContext::ChatService.new(
    client: client,
    model: settings.ollama_model,
    logger: RepoContext::Settings.logger
  )
end

def code_review_agent
  @code_review_agent ||= RepoContext::CodeReviewAgent.new(
    client: client,
    model: settings.ollama_model,
    context_builder: context_builder,
    logger: RepoContext::Settings.logger
  )
end

configure do
  set :ollama_client, RepoContext::OllamaClientFactory.build(
    model: RepoContext::Settings::OLLAMA_MODEL,
    temperature: RepoContext::Settings::OLLAMA_TEMPERATURE.to_f,
    timeout: RepoContext::Settings::OLLAMA_TIMEOUT
  )
  set :ollama_model, RepoContext::Settings::OLLAMA_MODEL
  RepoContext::Settings.logger.info do
    "chat server ready: port=#{settings.port}, context_path=#{RepoContext::Settings::REPO_ROOT}, " \
    "discovery=#{RepoContext::Settings::DISCOVERY_AGENT_ENABLED}, embed=#{RepoContext::Settings::EMBED_CONTEXT_ENABLED}, " \
    "context_max=#{RepoContext::Settings::CONTEXT_MAX_CHARS}, ollama=#{RepoContext::Settings::OLLAMA_BASE_URL}, " \
    "model=#{RepoContext::Settings::OLLAMA_MODEL}"
  end
end

get "/" do
  RepoContext::Settings.logger.debug { "GET /" }
  erb :index
end

def emit_stream_event(yielder, event, data = {})
  payload = { event: event }.merge(data)
  yielder << "#{payload.to_json}\n"
end

post "/api/chat" do
  request.body.rewind
  body = JSON.parse(request.body.read)
  message = body["message"].to_s.strip
  if message.empty?
    RepoContext::Settings.logger.warn { "api/chat: empty message" }
    status 422
    content_type :json
    return { error: "message is required" }.to_json
  end

  history = body["history"].is_a?(Array) ? body["history"] : []
  RepoContext::Settings.logger.info { "api/chat: request (history=#{history.size})" }

  repo_context = context_builder.gather(message)
  reply = chat_service.ask(
    message,
    repo_context: repo_context,
    conversation_history: history
  )
  new_history = history + [
    { "role" => "user", "content" => message },
    { "role" => "assistant", "content" => reply }
  ]
  content_type :json
  { response: reply, history: new_history }.to_json
rescue Ollama::Error => e
  RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
  status 502
  content_type :json
  { error: "Ollama error: #{e.message}" }.to_json
rescue JSON::ParserError => e
  RepoContext::Settings.logger.warn { "Invalid JSON body: #{e.message}" }
  status 422
  content_type :json
  { error: "Invalid JSON body" }.to_json
end

post "/api/chat/stream" do
  request.body.rewind
  body = JSON.parse(request.body.read)
  message = body["message"].to_s.strip
  if message.empty?
    status 422
    content_type :json
    return { error: "message is required" }.to_json
  end

  history = body["history"].is_a?(Array) ? body["history"] : []

  stream_body = Enumerator.new do |y|
    begin
      emit_stream_event(y, "status", message: "Gathering context…")
      repo_context = context_builder.gather(message)
      emit_stream_event(y, "status", message: "Asking Ollama…")
      reply = chat_service.ask(
        message,
        repo_context: repo_context,
        conversation_history: history
      )
      new_history = history + [
        { "role" => "user", "content" => message },
        { "role" => "assistant", "content" => reply }
      ]
      emit_stream_event(y, "done", response: reply, history: new_history)
    rescue Ollama::Error => e
      RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
      emit_stream_event(y, "error", error: "Ollama error: #{e.message}")
    rescue StandardError => e
      RepoContext::Settings.logger.error { "Stream error: #{e.message}" }
      emit_stream_event(y, "error", error: e.message.to_s)
    end
  end

  [200, { "Content-Type" => "application/x-ndjson; charset=utf-8" }, stream_body]
rescue JSON::ParserError
  status 422
  content_type :json
  { error: "Invalid JSON body" }.to_json
end

post "/api/review" do
  request.body.rewind
  body = JSON.parse(request.body.read)
  paths = body["paths"].is_a?(Array) ? body["paths"].map(&:to_s).reject(&:empty?) : []
  focus = body["focus"].to_s.strip
  focus = RepoContext::Settings::REVIEW_FOCUS if focus.empty?

  RepoContext::Settings.logger.info { "api/review: paths=#{paths.size}, focus=#{focus[0, 60]}..." }

  state = code_review_agent.run(request_paths: paths, focus: focus)
  summary = state.observations.last
  content_type :json
  {
    findings: state.findings,
    summary: summary,
    reviewed_paths: state.reviewed_paths,
    iterations: state.iteration
  }.to_json
rescue Ollama::Error => e
  RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
  status 502
  content_type :json
  { error: "Ollama error: #{e.message}" }.to_json
rescue JSON::ParserError => e
  RepoContext::Settings.logger.warn { "Invalid JSON body: #{e.message}" }
  status 422
  content_type :json
  { error: "Invalid JSON body" }.to_json
end

post "/api/review/stream" do
  request.body.rewind
  body = JSON.parse(request.body.read)
  paths = body["paths"].is_a?(Array) ? body["paths"].map(&:to_s).reject(&:empty?) : []
  focus = body["focus"].to_s.strip
  focus = RepoContext::Settings::REVIEW_FOCUS if focus.empty?

  stream_body = Enumerator.new do |y|
    begin
      emit_stream_event(y, "status", message: "Starting code review…")
      code_review_agent.run_with_events(request_paths: paths, focus: focus) do |event, iteration, payload|
        case event
        when :plan
          emit_stream_event(y, "status", message: "Planning step #{iteration + 1}…")
        when :review_file
          emit_stream_event(y, "review_file", path: payload)
        when :review_done
          emit_stream_event(y, "findings", findings: payload.findings, path: payload.reviewed_path)
        when :summarize
          emit_stream_event(y, "status", message: "Summarizing…")
        when :summary_done
          emit_stream_event(y, "summary", summary: payload.observation)
        when :done
          emit_stream_event(y, "done", findings: payload.findings, summary: payload.observations.last, reviewed_paths: payload.reviewed_paths, iterations: payload.iteration)
        end
      end
    rescue Ollama::Error => e
      RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
      emit_stream_event(y, "error", error: "Ollama error: #{e.message}")
    rescue StandardError => e
      RepoContext::Settings.logger.error { "Review error: #{e.message}" }
      emit_stream_event(y, "error", error: e.message.to_s)
    end
  end

  [200, { "Content-Type" => "application/x-ndjson; charset=utf-8" }, stream_body]
rescue JSON::ParserError
  status 422
  content_type :json
  { error: "Invalid JSON body" }.to_json
end
