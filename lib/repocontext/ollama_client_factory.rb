# frozen_string_literal: true

require "ollama_client"

module RepoContext
  module OllamaClientFactory
    def self.build(model:, temperature:, timeout:)
      config = Ollama::Config.new
      config.base_url = Settings::OLLAMA_BASE_URL
      config.model = model
      config.temperature = temperature
      config.timeout = timeout
      config.retries = 2
      Ollama::Client.new(config: config)
    end
  end
end
