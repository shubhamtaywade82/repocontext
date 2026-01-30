# Repo Context

Sinatra app that answers questions about a codebase using repo file contents and Ollama, and runs an **agentic code reviewer** (plan → act → observe → replan).

---

## Table of contents

- [Overview](#overview)
- [Dependencies](#dependencies)
- [Installation](#installation)
- [Configuration](#configuration)
- [Run](#run)
- [Usage](#usage)
- [API reference](#api-reference)
- [Project layout](#project-layout)
- [Examples](#examples)

---

## Overview

### Chat

Ask questions about the repo. Context is built from reference files, optional embeddings, and a discovery agent that picks extra files.

### Code Review

Agentic loop: the planner chooses the next file to review, the executor reviews it (e.g. Clean Ruby), findings are accumulated; when done, a summary is produced.

---

## Dependencies

- **Ruby** ≥ 3.0
- **Ollama** running and reachable (e.g. `ollama serve`). Pull a model: `ollama pull llama3.1:8b`

### Required gems (see Gemfile / Gemfile.lock for exact versions)

| Gem            | Version  | Purpose              |
|----------------|----------|----------------------|
| sinatra        | ~> 3.0   | Web app              |
| webrick        | (default)| HTTP server          |
| ollama-client  | ~> 0.2   | Ollama API           |
| dotenv         | (any)    | Optional .env loading|

### Optional

- **Embeddings**: For RAG, set `EMBED_CONTEXT_ENABLED=true` and run `ollama pull nomic-embed-text`.

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

| Variable Name           | Purpose                              | Default Value |
|-------------------------|--------------------------------------|---------------|
| REPO_CONTEXT_PATH       | Repo root for context                | Project root  |
| CONTEXT_FILES           | Comma-separated files loaded first   | README.md,Gemfile |
| CONTEXT_MAX_CHARS       | Max context size                     | 35000         |
| OLLAMA_BASE_URL         | Ollama API URL                       | http://192.168.1.4:11434 |
| OLLAMA_MODEL            | Model name                           | llama3.1:8b   |
| OLLAMA_TEMPERATURE      | Chat temperature                     | 0.5           |
| OLLAMA_TIMEOUT          | Request timeout (seconds)            | 60            |
| DISCOVERY_AGENT_ENABLED | Use LLM to pick extra files          | true          |
| EMBED_CONTEXT_ENABLED   | Use embeddings for context           | false         |
| REVIEW_MAX_ITERATIONS   | Max code review loop steps           | 15            |
| REVIEW_MAX_PATHS        | Max paths per review                 | 20            |
| REVIEW_FOCUS            | Default review focus                 | Clean Ruby focus string |
| LOG_LEVEL               | debug or info                        | info          |

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
