# Repo Context

Sinatra app that answers questions about a codebase using repo file contents and Ollama, and runs an **agentic code reviewer** (plan → act → observe → replan).

---

## Overview

- **Chat**: Ask questions about the repo; context is built from reference files, optional embeddings, and a discovery agent that picks extra files.
- **Code Review**: Agentic loop: planner chooses the next file to review, executor reviews it (e.g. Clean Ruby), findings are accumulated; when done, a summary is produced.

---

## Dependencies

- **Ruby** ≥ 3.0
- **Ollama** running and reachable (e.g. `ollama serve`). Pull a model: `ollama pull llama3.1:8b`
- **Gems**: `sinatra`, `webrick`, `ollama-client`, `dotenv` (see Gemfile)

### Optional

- **Embeddings**: For RAG, set `EMBED_CONTEXT_ENABLED=true` and run `ollama pull nomic-embed-text`.

---

## Installation

```bash
git clone <repo>
cd repocontext
bundle install
```

### Environment

Create a `.env` (or export) for overrides:

| Variable | Purpose | Default |
|----------|---------|---------|
| `REPO_CONTEXT_PATH` | Repo root for context | Project root |
| `CONTEXT_FILES` | Comma-separated files loaded first | `README.md,Gemfile` |
| `CONTEXT_MAX_CHARS` | Max context size | `35000` |
| `OLLAMA_BASE_URL` | Ollama API URL | `http://192.168.1.4:11434` |
| `OLLAMA_MODEL` | Model name | `llama3.1:8b` |
| `OLLAMA_TEMPERATURE` | Chat temperature | `0.5` |
| `OLLAMA_TIMEOUT` | Request timeout (s) | `60` |
| `DISCOVERY_AGENT_ENABLED` | Use LLM to pick extra files | `true` |
| `EMBED_CONTEXT_ENABLED` | Use embeddings for context | `false` |
| `REVIEW_MAX_ITERATIONS` | Max code review loop steps | `15` |
| `REVIEW_MAX_PATHS` | Max paths per review | `20` |
| `REVIEW_FOCUS` | Default review focus | Clean Ruby focus string |
| `LOG_LEVEL` | `debug` or `info` | `info` |

---

## Run

```bash
bundle exec ruby chat_server.rb
# or
bundle exec ruby bin/chat
```

Open http://localhost:4567 (or set `PORT=4568`).

---

## Usage

### Chat

1. Open the **Chat** tab.
2. Type a question about the codebase (e.g. "Where is the Ollama client configured?").
3. Response is based on repo context (reference files + discovery/embeddings).

**Example**: "What does the context builder load first?" → Answer will refer to `REFERENCE_FILES` and the flow in `ContextBuilder#gather`.

### Code Review

1. Open the **Code Review** tab.
2. Optionally set **Paths** (comma-separated, e.g. `lib/repocontext/chat_service.rb`) or leave empty to use discovered paths.
3. Optionally set **Focus** (e.g. "naming and method length") or use the default.
4. Click **Run code review**.

**Example output**: Findings stream per file (file, line, rule, message, severity); at the end a short summary with priorities and next steps.

### API

**POST /api/chat**

- Body: `{ "message": "your question", "history": [] }`
- Returns: `{ "response": "...", "history": [...] }`

**POST /api/chat/stream**

- Same body; NDJSON stream: `status`, `done` (with `response`, `history`), `error`.

**POST /api/review**

- Body: `{ "paths": ["lib/foo.rb"], "focus": "optional" }`
- Returns: `{ "findings": [...], "summary": "...", "reviewed_paths": [...], "iterations": N }`

**POST /api/review/stream**

- Same body; NDJSON stream: `status`, `review_file`, `findings`, `summary`, `done`, `error`.

---

## Project layout

```
repocontext/
├── bin/chat              # Server entrypoint
├── config/settings.rb    # Env-based config
├── lib/
│   ├── repocontext.rb
│   └── repocontext/
│       ├── version.rb
│       ├── ollama_client_factory.rb   # Cached Ollama client
│       ├── context_builder.rb         # Gather repo context
│       ├── chat_service.rb            # Chat with Ollama
│       ├── review_state.rb            # Review loop state
│       ├── review_plan_step.rb        # Plan step (review_file / done)
│       ├── file_review_outcome.rb     # Result of one file review
│       ├── review_planner.rb          # LLM: next file or done
│       ├── review_step_executor.rb    # LLM: review file, summary
│       └── code_review_agent.rb       # Agentic review loop
├── views/index.erb       # Chat + Code Review UI
├── chat_server.rb        # Sinatra routes and helpers
├── Gemfile
└── README.md
```

---

## Examples (no server)

Run Ollama client examples (planner, thinking, schema, multi-turn):

```bash
bundle exec ruby examples/ollama-client.rb
```

Set `OLLAMA_BASE_URL` and `OLLAMA_MODEL` as needed.
