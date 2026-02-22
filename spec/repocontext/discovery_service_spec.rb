# frozen_string_literal: true

require "spec_helper"
require "repocontext/discovery_service"

RSpec.describe RepoContext::DiscoveryService do
  let(:model) { "test-model" }
  let(:logger) { Logger.new(nil) }
  let(:service) { described_class.new(model: model, logger: logger) }
  let(:mock_client) { instance_double(Ollama::Client) }
  let(:mock_agent) { instance_double(AgentRuntime::AgentFSM) }

  before do
    allow(Ollama::Client).to receive(:new).and_return(mock_client)
    allow(AgentRuntime::AgentFSM).to receive(:new).and_return(mock_agent)

    # Mock CLIStdioTransport to prevent PTY spawning
    allow(RepoContext::CLIStdioTransport).to receive(:new).and_return(
      instance_double(RepoContext::CLIStdioTransport, send_request: { "result" => {} }, close: nil)
    )
  end

  describe "#run" do
    let(:query) { "Test query" }

    it "sets up connections and runs the agent" do
      expect(mock_agent).to receive(:run).with(initial_input: query).and_return({ final_message: "Found it!" })

      result = service.run(query)
      expect(result).to eq("Found it!")
    end

    it "handles agent failures gracefully" do
      expect(mock_agent).to receive(:run).and_return({ error: "failed" })

      result = service.run(query)
      expect(result).to include("failed")
    end

    it "cleans up transports even on failure" do
      expect(mock_agent).to receive(:run).and_raise(StandardError, "crash")

      expect { service.run(query) }.to raise_error(StandardError, "crash")
    end
  end
end
