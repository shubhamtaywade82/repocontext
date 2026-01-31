# frozen_string_literal: true
# Run: bundle exec ruby chat_server.rb  then open http://localhost:<PORT>
# PORT=4568 to use a different port. LOG_LEVEL=debug for more detail.
# Context: REPO_CONTEXT_PATH, CONTEXT_FILES, CONTEXT_MAX_CHARS, DISCOVERY_AGENT_ENABLED.
# Embeddings: EMBED_CONTEXT_ENABLED=true, OLLAMA_EMBED_MODEL=nomic-embed-text (ollama pull nomic-embed-text).

$LOAD_PATH.unshift(File.expand_path("lib", __dir__))
require "repocontext/server"

# Allow Ctrl+C to stop the process even when a request is blocked (e.g. review stream in Ollama).
# First Ctrl+C sets a flag so the review loop can exit between steps; second Ctrl+C forces exit.
Signal.trap("INT") do
  if RepoContext::Settings.shutdown_requested?
    $stderr.puts "\nForce exit."
    exit(130)
  end
  RepoContext::Settings.request_shutdown!
  $stderr.puts "\nShutting down... (Ctrl+C again to force exit)"
end

RepoContext::Server.run! port: ENV.fetch("PORT", 4567).to_i
