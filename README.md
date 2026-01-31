# Repo Context

Sinatra app that answers questions about a codebase using repo file contents and Ollama, and runs an **agentic code reviewer** (plan → act → observe → replan).

---

## Table of contents

- [Overview](#overview)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Configuration](#configuration)
- [Performance](#performance)
- [Run](#run)
- [Usage](#usage)
- [API reference](#api-reference)
- [Project layout](#project-layout)
- [Examples](#examples)

---

## Overview

### Chat

Ask questions about the repo. Context is built from reference files, **embeddings** (RAG, on by default), and a discovery agent that picks extra files.

### Code Review

Agentic loop: the planner chooses the next file to review, the executor reviews it (e.g. Clean Ruby), findings are accumulated; when done, a summary is produced.

---

## Dependencies

- **Ruby** ≥ 3.0
- **Ollama** running and reachable (e.g. `ollama serve`). Pull a model: `ollama pull llama3.1:8b-instruct-q4_K_M`

### Required gems (see Gemfile / Gemfile.lock for exact versions)

| Gem           | Version   | Purpose               |
| ------------- | --------- | --------------------- |
| sinatra       | ~> 3.0    | Web app               |
| webrick       | (default) | HTTP server           |
| ollama-client | ~> 0.2    | Ollama API            |
| dotenv        | (any)     | Optional .env loading |

### Embeddings (on by default)

- RAG uses embeddings to add relevant chunks per question. Run `ollama pull nomic-embed-text:v1.5` before using (requires Ollama 0.1.26+).
- Set `EMBED_CONTEXT_ENABLED=false` to disable. Tune `EMBED_TOP_K`, `EMBED_MAX_CHUNKS`, `EMBED_MIN_QUESTION_LENGTH` for efficiency.

---

## Installation

```bash
git clone <repo>
cd repocontext
bundle install
```

No database or migrations; the app uses the filesystem and Ollama only.

---

## Configuration

Create a `.env` (or export) for overrides:

| Variable Name             | Purpose                             | Default Value               |
| ------------------------- | ----------------------------------- | --------------------------- |
| REPO_CONTEXT_PATH         | Repo root for context               | Project root                |
| CONTEXT_FILES             | Comma-separated files loaded first  | README.md,Gemfile           |
| CONTEXT_MAX_CHARS         | Max context size                    | 35000                       |
| OLLAMA_BASE_URL           | Ollama API URL                      | http://localhost:11434    |
| OLLAMA_MODEL              | Primary reasoning (chat, planning)  | llama3.1:8b-instruct-q4_K_M |
| OLLAMA_CODE_MODEL         | Code review / generation            | qwen2.5-coder:7b            |
| OLLAMA_EMBED_MODEL        | Embeddings (RAG)                    | nomic-embed-text:v1.5       |
| OLLAMA_TEMPERATURE        | Chat temperature                    | 0.5                         |
| OLLAMA_TIMEOUT            | Request timeout (seconds)           | 60                          |
| DISCOVERY_AGENT_ENABLED   | Use LLM to pick extra files         | true                        |
| EMBED_CONTEXT_ENABLED     | Use embeddings for context          | true                        |
| EMBED_TOP_K               | Max similar chunks to add per query | 5                           |
| EMBED_MAX_CHUNKS          | Max chunks in index (efficiency)    | 60                          |
| EMBED_MIN_QUESTION_LENGTH | Min question length to run embed    | 3                           |
| REVIEW_MAX_ITERATIONS     | Max code review loop steps          | 15                          |
| REVIEW_MAX_PATHS          | Max paths per review                | 20                          |
| REVIEW_FOCUS              | Default review focus                | Clean Ruby focus string     |
| CANDIDATE_MAX_FILE_SIZE   | Skip files larger than (bytes); 0=no limit | 500000                |
| CANDIDATE_EXCLUDE_PATTERNS| Comma-separated fnmatch patterns    | (none)                      |
| EMBED_PARALLEL_CHUNKS     | Parallel embed requests per file    | 1 (sequential)              |
| LOG_LEVEL                 | debug or info                       | info                        |

---

## Performance

- **Embedding cache**: Embeddings are stored in SQLite (`repocontext.db`). Unchanged files (by mtime) are not re-embedded. WAL mode and indexes are used for faster reads.
- **File filtering**: Discovery and code review skip files over `CANDIDATE_MAX_FILE_SIZE` and paths matching `CANDIDATE_EXCLUDE_PATTERNS` (e.g. `vendor/*,*.min.js`).
- **Parallel embedding**: Set `EMBED_PARALLEL_CHUNKS` (e.g. 4) to embed chunks of new/modified files in parallel (more load on Ollama).
- **Streaming**: Use `/api/chat/stream` and `/api/review/stream` for incremental status and results without blocking.
- **Limits**: `REVIEW_MAX_PATHS`, `REVIEW_MAX_ITERATIONS`, `CANDIDATE_PATHS_MAX`, and `CONTEXT_MAX_CHARS` cap work per request.

---

## Run

```bash
bundle exec ruby chat_server.rb
# or
bundle exec ruby bin/chat
```

Open http://localhost:4567 (or set `PORT=4568`).

To stop the server: press **Ctrl+C** in the terminal where it is running.

---

## Usage

### Chat

1. Open the **Chat** tab.
2. Type a question about the codebase (e.g. "Where is the Ollama client configured?").
3. Response is based on repo context (reference files + discovery/embeddings).

### Code Review

1. Open the **Code Review** tab.
2. Optionally set **Paths** (comma-separated) or leave empty to use discovered paths.
3. Optionally set **Focus** (e.g. "naming and method length") or use the default.
4. Click **Run code review**.

---

## API reference

### POST /api/chat

**Request body**

```json
{ "message": "your question", "history": [] }
```

**Success (200)**

```json
{ "response": "answer text", "history": [ { "role": "user", "content": "..." }, { "role": "assistant", "content": "..." } ] }
```

**Error (422)** – missing or empty message

```json
{ "error": "message is required" }
```

**Error (502)** – Ollama unreachable or error

```json
{ "error": "Ollama error: <message>" }
```

---

### POST /api/chat/stream

Same body as `/api/chat`. Response is NDJSON stream:

- `{"event":"status","message":"..."}` – progress
- `{"event":"done","response":"...","history":[...]}` – completion
- `{"event":"error","error":"..."}` – failure

---

### POST /api/review

**Request body**

```json
{ "paths": ["lib/foo.rb"], "focus": "optional focus" }
```

**Success (200)**

```json
{
  "findings": [ { "file": "...", "line": 1, "rule": "...", "message": "...", "severity": "suggestion" } ],
  "summary": "paragraph",
  "reviewed_paths": ["lib/foo.rb"],
  "iterations": 3
}
```

**Error (422)** – invalid JSON body

```json
{ "error": "Invalid JSON body" }
```

**Error (502)** – Ollama error

```json
{ "error": "Ollama error: <message>" }
```

---

### POST /api/review/stream

Same body as `/api/review`. NDJSON stream: `status`, `review_file`, `findings`, `summary`, `done`, `error`.

---

## Project layout (SOLID-oriented)

```
repocontext/
├── bin/chat                    # Server entrypoint
├── config/settings.rb          # Env-based config
├── lib/
│   ├── repocontext.rb
│   └── repocontext/
│       ├── version.rb
│       ├── ollama_client_factory.rb     # Cached Ollama client (DIP)
│       ├── discovery_path_selector.rb   # SRP: scan repo + LLM pick paths
│       ├── embedding_context_builder.rb # SRP: embed index + context_for_question
│       ├── context_builder.rb           # Orchestrates context
│       ├── chat_service.rb              # Chat with Ollama
│       ├── review_state.rb              # Review loop state
│       ├── review_plan_step.rb          # Plan step (review_file / done)
│       ├── file_review_outcome.rb       # Result of one file review
│       ├── review_planner.rb            # LLM: next file or done
│       ├── review_step_executor.rb      # SRP: review one file → findings
│       ├── review_summary_writer.rb     # SRP: state → summary outcome
│       └── code_review_agent.rb         # Agentic loop
├── views/index.erb             # Chat + Code Review UI
├── chat_server.rb              # Sinatra routes, wires dependencies
├── Gemfile
└── README.md
```

---

## Examples

Run Ollama client examples (no server):

```bash
bundle exec ruby examples/ollama-client.rb
```

Set `OLLAMA_BASE_URL` and `OLLAMA_MODEL` as needed.
