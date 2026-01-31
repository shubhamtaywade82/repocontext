# frozen_string_literal: true

require "rspec"
require "rack/test"
require "repocontext/server"

ENV["RACK_ENV"] = "test"

# Disable real Ollama calls for basic testing if desired, or mock them.
# For now, we'll let them try effectively but maybe we should mock?
# Let's mock the OllamaClient to avoid needing a running Ollama instance for unit tests.

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups

  config.include Rack::Test::Methods
end
