# frozen_string_literal: true

require "spec_helper"

RSpec.describe RepoContext::Server do
  def app
    RepoContext::Server
  end

  # Mock the Settings and Client
  let(:mock_client) { instance_double("Ollama::Client") }

  before do
    allow(RepoContext::OllamaClientFactory).to receive(:build).and_return(mock_client)
  end

  describe "GET /" do
    it "loads the index page" do
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("RepoContext")
    end
  end

  describe "POST /api/chat" do
    let(:valid_params) do
      {
        "message" => "Hello context",
        "history" => []
      }
    end

    before do
      # Mock the chain of objects or methods if possible
      # Or just mock the service that handles it since we test the controller.
      # For now, deeply mocking might be hard due to how they are instantiated in helpers.

      # We'll just mock the client behavior essentially or the instance variables if we can reach them?
      # Sinatra helpers mix into the app instance.

      # Let's mock the `repo_chat_service` which is used in the route.
      # Since it's a helper method, we can try to mock AnyInstance of Server? No, that's hard.
      # Easier to mock `RepoContext::ChatService.new`
    end

    it "returns error if message is empty" do
      post "/api/chat", { "message" => "" }.to_json
      expect(last_response.status).to eq(422)
    end
  end
end
