# Repo Context

Sinatra app that answers questions about a codebase using repo file contents and Ollama. Supports base context files, discovery agent, optional RAG (embeddings), and model-name boost paths.

## Layout

```
repocontext/
├── bin/chat           # Run the server: bundle exec ruby bin/chat
├── config/
│   └── settings.rb    # Env-based config (REPO_ROOT, OLLAMA_*, CONTEXT_*, etc.)
├── lib/
│   ├── repocontext.rb
│   └── repocontext/
│       ├── version.rb
│       ├── ollama_client_factory.rb
│       ├── context_builder.rb   # Load files, discovery, embeddings, gather context
│       └── chat_service.rb     # ask via chat_raw / generate
├── views/
│   └── index.erb      # Chat UI
├── examples/
│   └── ollama-client.rb  # Standalone Ollama usage examples (planner, thinking, schema)
├── chat_server.rb     # Sinatra app: routes and wiring
├── Gemfile
└── README.md
```

## Run

```bash
bundle install
bundle exec ruby chat_server.rb
# or
bundle exec ruby bin/chat
```

Then open http://localhost:4567 (or set `PORT=4568`).

## Config (env)

- **REPO_CONTEXT_PATH** – Repo root to build context from (default: this project).
- **CONTEXT_FILES** – Comma-separated list of files to load first (default: `README.md,Gemfile`).
- **CONTEXT_MAX_CHARS** – Max chars for context (default: 35000).
- **DISCOVERY_AGENT_ENABLED** – Use LLM to pick extra files (default: true).
- **OLLAMA_BASE_URL**, **OLLAMA_MODEL**, **OLLAMA_TEMPERATURE**, **OLLAMA_TIMEOUT** – Ollama client.
- **EMBED_CONTEXT_ENABLED** – Enable RAG with embeddings (default: false). Requires `ollama pull nomic-embed-text` and **OLLAMA_EMBED_MODEL**.
- **LOG_LEVEL** – `debug` or `info` (default: info).

## Examples

Run Ollama client examples (no server):

```bash
bundle exec ruby examples/ollama-client.rb
```

Override Ollama URL/model via env as needed.
