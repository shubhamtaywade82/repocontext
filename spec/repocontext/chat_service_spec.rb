# frozen_string_literal: true

require "spec_helper"
require "repocontext/chat_service"

RSpec.describe RepoContext::ChatService do
  let(:client) { double("Ollama::Client") }
  let(:model) { "test-model" }
  let(:service) { described_class.new(client: client, model: model) }

  describe "#ask" do
    it "uses AgentRuntime::Planner to chat" do
      messages = [
        { role: "system", content: /You are a helpful assistant/ },
        { role: "user", content: "Hello" }
      ]

      # Note: AgentRuntime::Planner translates its initialize kwargs into top_level_kwargs or api_options
      # and calls client.chat with messages and those options.
      expect(client).to receive(:chat).with(
        hash_including(
          messages: array_including(hash_including(role: "user", content: "Hello")),
          model: model,
          think: true # Verified from ChatService#initialize
        )
      ).and_return({ "message" => { "content" => "Hi there!" } })

      result = service.ask("Hello", repo_context: "context", conversation_history: [])
      expect(result).to eq("Hi there!")
    end

    it "falls back to ask_via_generate on error" do
      expect(client).to receive(:chat).and_raise(StandardError.new("API Error"))
      expect(service).to receive(:ask_via_generate).and_return("fallback")

      result = service.ask("Hello", repo_context: "context", conversation_history: [])
      expect(result).to eq("fallback")
    end
  end

  describe "#ask_via_generate" do
    it "uses AgentRuntime::Planner to plan with schema" do
      expect(client).to receive(:generate).with(
        hash_including(
          prompt: /Question: What is X/,
          schema: RepoContext::ChatService::SIMPLE_RESPONSE_SCHEMA,
          model: model
        )
      ).and_return({ "response" => "It is X" })

      result = service.ask_via_generate("What is X", repo_context: "context")
      expect(result).to eq("It is X")
    end
  end
end
