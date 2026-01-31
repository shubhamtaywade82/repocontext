# frozen_string_literal: true
# Run: bundle exec ruby chat_server.rb  then open http://localhost:<PORT>
# PORT=4568 to use a different port. LOG_LEVEL=debug for more detail.
# Context: REPO_CONTEXT_PATH, CONTEXT_FILES, CONTEXT_MAX_CHARS, DISCOVERY_AGENT_ENABLED.
# Embeddings: EMBED_CONTEXT_ENABLED=true, OLLAMA_EMBED_MODEL=nomic-embed-text:v1.5 (ollama pull nomic-embed-text:v1.5).

# Prepend lib so require "repocontext/server" resolves; avoid adding elsewhere to prevent path pollution.
$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "repocontext/server"

# First INT: set shutdown flag so long-running review loop can exit between steps.
# Second INT: force exit. Sinatra/WEBrick do not stop from inside the trap; the flag is the contract.
Signal.trap("INT") do
  if RepoContext::Settings.shutdown_requested?
    $stderr.puts "\nForce exit."
    exit(130)
  end
  RepoContext::Settings.request_shutdown!
  $stderr.puts "\nShutting down... (Ctrl+C again to force exit)"
end

begin
  RepoContext::Server.run! port: ENV.fetch("PORT", 4567).to_i
rescue StandardError => e
  RepoContext::Settings.logger.error { "Server failed: #{e.class} - #{e.message}" }
  raise
end
