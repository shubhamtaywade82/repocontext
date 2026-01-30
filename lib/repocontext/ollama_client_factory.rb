# frozen_string_literal: true

require "ollama_client"

module RepoContext
  module OllamaClientFactory
    CLIENT_CACHE = { mutex: Mutex.new, clients: {} }.freeze

    def self.build(model:, temperature:, timeout:)
      client_cache_key = [model, temperature, timeout].freeze
      CLIENT_CACHE[:mutex].synchronize do
        return CLIENT_CACHE[:clients][client_cache_key] if CLIENT_CACHE[:clients].key?(client_cache_key)

        ollama_config = build_config(model: model, temperature: temperature, timeout: timeout)
        ollama_client = Ollama::Client.new(config: ollama_config)
        CLIENT_CACHE[:clients][client_cache_key] = ollama_client
        ollama_client
      end
    end

    def self.build_config(model:, temperature:, timeout:)
      ollama_config = Ollama::Config.new
      apply_base_config(ollama_config, model: model, temperature: temperature, timeout: timeout)
      ollama_config.retries = 2
      ollama_config
    end

    def self.apply_base_config(config, model:, temperature:, timeout:)
      config.base_url = Settings::OLLAMA_BASE_URL
      config.model = model
      config.temperature = temperature
      config.timeout = timeout
    end
  end
end
