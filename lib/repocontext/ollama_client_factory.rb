# frozen_string_literal: true

require "ollama_client"

module RepoContext
  module OllamaClientFactory
    CACHE = { mutex: Mutex.new, clients: {} }.freeze

    def self.build(model:, temperature:, timeout:)
      cache_key = [model, temperature, timeout].freeze
      CACHE[:mutex].synchronize do
        return CACHE[:clients][cache_key] if CACHE[:clients].key?(cache_key)

        config = build_config(model: model, temperature: temperature, timeout: timeout)
        client = Ollama::Client.new(config: config)
        CACHE[:clients][cache_key] = client
        client
      end
    end

    def self.build_config(model:, temperature:, timeout:)
      config = Ollama::Config.new
      config.base_url = Settings::OLLAMA_BASE_URL
      config.model = model
      config.temperature = temperature
      config.timeout = timeout
      config.retries = 2
      config
    end
  end
end
