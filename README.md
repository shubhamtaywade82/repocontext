# Repo Context

Sinatra app that answers questions about a codebase using repo file contents and Ollama. Supports base context files, discovery agent, optional RAG (embeddings), and an **agentic code reviewer** with plan → act → observe → replan looping.

## Layout

```
repocontext/
├── bin/chat           # Run the server: bundle exec ruby bin/chat
├── config/
│   └── settings.rb    # Env-based config (REPO_ROOT, OLLAMA_*, CONTEXT_*, REVIEW_*, etc.)
├── lib/
│   ├── repocontext.rb
│   └── repocontext/
│       ├── version.rb
│       ├── ollama_client_factory.rb
│       ├── context_builder.rb   # Load files, discovery, embeddings, gather context
│       ├── chat_service.rb      # ask via chat_raw / generate
│       ├── review_state.rb      # State for agentic review loop
│       ├── review_plan_step.rb  # Plan step (review_file / done)
│       ├── review_step_result.rb
│       ├── review_planner.rb    # LLM: next file or done
│       ├── review_step_executor.rb  # LLM: review one file, return findings
│       └── code_review_agent.rb # Agentic loop: plan → execute → observe until done
├── views/
│   └── index.erb      # Chat + Code Review tabs
├── examples/
│   └── ollama-client.rb  # Standalone Ollama usage examples
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
- **REVIEW_MAX_ITERATIONS** – Max steps in the code review loop (default: 15).
- **REVIEW_MAX_PATHS** – Max file paths to consider per review (default: 20).
- **REVIEW_FOCUS** – Default review focus (e.g. Clean Ruby, naming, single responsibility).
- **LOG_LEVEL** – `debug` or `info` (default: info).

## Code Review Agent

The **Code Review** tab runs an agentic loop:

1. **Plan** – LLM chooses the next file to review (or signals done).
2. **Act** – LLM reviews that file against the focus (e.g. Clean Ruby) and returns findings.
3. **Observe** – Findings and a short observation are added to state.
4. **Replan** – Planner sees updated state and picks the next file (or done).
5. When no files remain, the agent runs a **summary** step and returns findings + summary.

- **POST /api/review** – Body: `{ "paths": ["lib/foo.rb"], "focus": "optional" }`. Returns `{ findings, summary, reviewed_paths, iterations }`.
- **POST /api/review/stream** – Same body; streams events: `status`, `review_file`, `findings`, `summary`, `done`, `error`.

Leave `paths` empty to use the repo’s discovered candidate paths (same as discovery agent).

## Examples

Run Ollama client examples (no server):

```bash
bundle exec ruby examples/ollama-client.rb
```

Override Ollama URL/model via env as needed.
