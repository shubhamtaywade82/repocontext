# frozen_string_literal: true

require "connection_pool"

module RepoContext
  # Connection pool for Ollama clients to handle concurrent requests efficiently
  class OllamaClientPool
    def initialize(size: Settings::OLLAMA_CLIENT_POOL_SIZE, timeout: 5, logger: Settings.logger)
      @log = logger
      @pool = ConnectionPool.new(size: size, timeout: timeout) do
        build_client
      end
      @log.info { "Ollama client pool initialized: size=#{size}, timeout=#{timeout}s" }
    end

    def with(&block)
      @pool.with(&block)
    end

    def size
      @pool.size
    end

    def available
      @pool.available
    end

    private

    def build_client
      OllamaClientFactory.build(
        model: Settings::OLLAMA_MODEL,
        temperature: Settings::OLLAMA_TEMPERATURE.to_f,
        timeout: Settings::OLLAMA_TIMEOUT
      )
    rescue StandardError => e
      @log.error { "Failed to create Ollama client: #{e.message}" }
      raise
    end
  end
end
