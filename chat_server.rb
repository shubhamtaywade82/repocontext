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
  return nil unless RepoContext::Settings::EMBED_CONTEXT_ENABLED

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
      model: settings.ollama_model,
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
  message, history = parse_chat_request
  return json_error(422, "message is required") if message.empty?

  repo_context = repo_context_builder.gather(message)
  reply_text = repo_chat_service.ask(
    message,
    repo_context: repo_context,
    conversation_history: history
  )
  new_history = history + [
    { "role" => "user", "content" => message },
    { "role" => "assistant", "content" => reply_text }
  ]
  content_type :json
  { response: reply_text, history: new_history }.to_json
rescue Ollama::Error => e
  return log_and_respond_ollama_error(e)
rescue JSON::ParserError => e
  RepoContext::Settings.logger.warn { "Invalid JSON body: #{e.message}" }
  return json_error(422, "Invalid JSON body")
end

post "/api/chat/stream" do
  message, history = parse_chat_request
  return json_error(422, "message is required") if message.empty?

  stream_body = build_chat_stream(message, history)
  [200, { "Content-Type" => "application/x-ndjson; charset=utf-8" }, stream_body]
rescue JSON::ParserError
  json_error(422, "Invalid JSON body")
end

post "/api/review" do
  paths, focus = parse_review_request
  RepoContext::Settings.logger.info { "api/review: paths=#{paths.size}, focus=#{focus[0, 60]}..." }

  review_state = code_review_agent.run(request_paths: paths, focus: focus)
  content_type :json
  {
    findings: review_state.findings,
    summary: review_state.observations.last,
    reviewed_paths: review_state.reviewed_paths,
    iterations: review_state.iteration
  }.to_json
rescue Ollama::Error => e
  return log_and_respond_ollama_error(e)
rescue JSON::ParserError => e
  RepoContext::Settings.logger.warn { "Invalid JSON body: #{e.message}" }
  return json_error(422, "Invalid JSON body")
end

post "/api/review/stream" do
  paths, focus = parse_review_request
  stream_body = build_review_stream(paths, focus)
  [200, { "Content-Type" => "application/x-ndjson; charset=utf-8" }, stream_body]
rescue JSON::ParserError
  json_error(422, "Invalid JSON body")
end

def parse_chat_request
  request.body.rewind
  body = JSON.parse(request.body.read)
  message = body["message"].to_s.strip
  history = body["history"].is_a?(Array) ? body["history"] : []
  RepoContext::Settings.logger.info { "api/chat: request (history=#{history.size})" }
  [message, history]
end

def parse_review_request
  request.body.rewind
  body = JSON.parse(request.body.read)
  paths = body["paths"].is_a?(Array) ? body["paths"].map(&:to_s).reject(&:empty?) : []
  focus = body["focus"].to_s.strip
  focus = RepoContext::Settings::REVIEW_FOCUS if focus.empty?
  [paths, focus]
end

def build_chat_stream(message, history)
  Enumerator.new do |yielder|
    emit_stream_event(yielder, "status", message: "Gathering context…")
    repo_context = repo_context_builder.gather(message)
    emit_stream_event(yielder, "status", message: "Asking Ollama…")
    reply_text = repo_chat_service.ask(
      message,
      repo_context: repo_context,
      conversation_history: history
    )
    new_history = history + [
      { "role" => "user", "content" => message },
      { "role" => "assistant", "content" => reply_text }
    ]
    emit_stream_event(yielder, "done", response: reply_text, history: new_history)
  rescue Ollama::Error => e
    RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
    emit_stream_event(yielder, "error", error: "Ollama error: #{e.message}")
  end
end

def build_review_stream(paths, focus)
  Enumerator.new do |yielder|
    emit_stream_event(yielder, "status", message: "Starting code review…")
    code_review_agent.run_with_events(request_paths: paths, focus: focus) do |event, iteration, payload|
      emit_review_event(yielder, event, iteration, payload)
    end
  rescue Ollama::Error => e
    RepoContext::Settings.logger.error { "Ollama error: #{e.message}" }
    emit_stream_event(yielder, "error", error: "Ollama error: #{e.message}")
  end
end

def emit_review_event(yielder, event, iteration, payload)
  case event
  when :plan
    emit_stream_event(yielder, "status", message: "Planning step #{iteration + 1}…")
  when :review_file
    emit_stream_event(yielder, "review_file", path: payload)
  when :review_done
    emit_stream_event(yielder, "findings", findings: payload.findings, path: payload.reviewed_path)
  when :summarize
    emit_stream_event(yielder, "status", message: "Summarizing…")
  when :summary_done
    emit_stream_event(yielder, "summary", summary: payload.observation)
  when :done
    emit_stream_event(yielder, "done",
      findings: payload.findings,
      summary: payload.observations.last,
      reviewed_paths: payload.reviewed_paths,
      iterations: payload.iteration)
  end
end

def log_and_respond_ollama_error(error)
  RepoContext::Settings.logger.error { "Ollama error: #{error.message}" }
  status 502
  content_type :json
  { error: "Ollama error: #{error.message}" }.to_json
end

def json_error(status_code, message)
  status status_code
  content_type :json
  { error: message }.to_json
end
