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

    OLLAMA_BASE_URL = ENV.fetch("OLLAMA_BASE_URL", "http://192.168.1.4:11434")
    OLLAMA_MODEL = ENV.fetch("OLLAMA_MODEL", "llama3.1:8b")
    OLLAMA_TEMPERATURE = ENV.fetch("OLLAMA_TEMPERATURE", "0.5")
    OLLAMA_TIMEOUT = ENV.fetch("OLLAMA_TIMEOUT", 60).to_i
    OLLAMA_EMBED_MODEL = ENV.fetch("OLLAMA_EMBED_MODEL", "nomic-embed-text")

    EMBED_CONTEXT_ENABLED = ENV.fetch("EMBED_CONTEXT_ENABLED", "false").downcase == "true"
    EMBED_TOP_K = ENV.fetch("EMBED_TOP_K", 5).to_i
    EMBED_CHUNK_SIZE = ENV.fetch("EMBED_CHUNK_SIZE", 2000).to_i
    EMBED_CHUNK_OVERLAP = ENV.fetch("EMBED_CHUNK_OVERLAP", 200).to_i
    EMBED_MAX_CHUNKS = ENV.fetch("EMBED_MAX_CHUNKS", 100).to_i

    LOG_LEVEL = (ENV["LOG_LEVEL"] || "info").downcase

    def self.logger
      @logger ||= begin
        l = Logger.new($stdout)
        l.level = LOG_LEVEL == "debug" ? Logger::DEBUG : Logger::INFO
        l.formatter = proc { |severity, datetime, _progname, msg| "[#{datetime.strftime('%H:%M:%S')}] #{severity}: #{msg}\n" }
        l
      end
    end
  end
end
