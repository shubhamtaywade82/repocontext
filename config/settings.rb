# frozen_string_literal: true

require "logger"

module RepoContext
  module Settings
    REPO_ROOT = ENV.key?("REPO_CONTEXT_PATH") ? File.expand_path(ENV["REPO_CONTEXT_PATH"]) : File.expand_path("..", __dir__)
    REFERENCE_FILES = (ENV["CONTEXT_FILES"]&.split(/\s*,\s*/) || %w[README.md Gemfile]).freeze
    FALLBACK_CONTEXT_FILES = %w[README.md Gemfile package.json].freeze
    CONTEXT_MAX_CHARS = ENV.fetch("CONTEXT_MAX_CHARS", 35_000).to_i
    DISCOVERY_AGENT_ENABLED = ENV.fetch("DISCOVERY_AGENT_ENABLED", "true").downcase == "true"
    CANDIDATE_PATHS_MAX = 80
    DISCOVERY_PATHS_MAX = 5

    REVIEW_MAX_ITERATIONS = ENV.fetch("REVIEW_MAX_ITERATIONS", 15).to_i
    REVIEW_MAX_PATHS = ENV.fetch("REVIEW_MAX_PATHS", 20).to_i
    REVIEW_FOCUS = ENV.fetch("REVIEW_FOCUS", "Clean Ruby: naming, single responsibility, short methods, guard clauses").freeze

    OLLAMA_BASE_URL = ENV.fetch("OLLAMA_BASE_URL", "http://192.168.1.4:11434")
    DEFAULT_OLLAMA_MODEL = "llama3.1:8b-instruct-q4_K_M"
    DEFAULT_OLLAMA_CODE_MODEL = "qwen2.5-coder:7b"
    DEPRECATED_MODEL_ALIASES = %w[nemesis-coder nemesis-coder:latest].freeze

    def self.resolve_model(env_key, default)
      raw = ENV.fetch(env_key, default)
      DEPRECATED_MODEL_ALIASES.include?(raw.to_s.strip) ? default : raw
    end
    private_class_method :resolve_model

    OLLAMA_MODEL = resolve_model("OLLAMA_MODEL", DEFAULT_OLLAMA_MODEL)
    OLLAMA_CODE_MODEL = resolve_model("OLLAMA_CODE_MODEL", DEFAULT_OLLAMA_CODE_MODEL)
    OLLAMA_TEMPERATURE = ENV.fetch("OLLAMA_TEMPERATURE", "0.5")
    OLLAMA_TIMEOUT = ENV.fetch("OLLAMA_TIMEOUT", 60).to_i
    OLLAMA_EMBED_MODEL = ENV.fetch("OLLAMA_EMBED_MODEL", "nomic-embed-text:latest")

    EMBED_CONTEXT_ENABLED = ENV.fetch("EMBED_CONTEXT_ENABLED", "true").downcase == "true"
    EMBED_TOP_K = ENV.fetch("EMBED_TOP_K", 5).to_i
    EMBED_CHUNK_SIZE = ENV.fetch("EMBED_CHUNK_SIZE", 2000).to_i
    EMBED_CHUNK_OVERLAP = ENV.fetch("EMBED_CHUNK_OVERLAP", 200).to_i
    EMBED_MAX_CHUNKS = ENV.fetch("EMBED_MAX_CHUNKS", 60).to_i
    EMBED_MIN_QUESTION_LENGTH = ENV.fetch("EMBED_MIN_QUESTION_LENGTH", "3").to_i

    LOG_LEVEL = (ENV["LOG_LEVEL"] || "info").downcase

    # Set by SIGINT handler; long-running loops (e.g. code review) check this to exit cleanly.
    def self.shutdown_requested?
      @shutdown_requested == true
    end

    def self.request_shutdown!
      @shutdown_requested = true
    end

    def self.logger
      @logger ||= begin
        log_instance = Logger.new($stdout)
        log_instance.level = LOG_LEVEL == "debug" ? Logger::DEBUG : Logger::INFO
        log_instance.formatter = proc { |severity, datetime, _progname, msg| "[#{datetime.strftime('%H:%M:%S')}] #{severity}: #{msg}\n" }
        log_instance
      end
    end
  end
end
