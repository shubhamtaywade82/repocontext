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
    it "returns 422 when message is empty" do
      post "/api/chat", { "message" => "" }.to_json, { "CONTENT_TYPE" => "application/json" }
      expect(last_response.status).to eq(422)
    end
  end
end
