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

  describe "#suggested_questions" do
    # Helpers are mixed into the app class instance, so we can test via specific route or better yet,
    # test that the index page renders them since we can't easily access the helper method directly
    # without a complex setup in rack-test (helpers are private/protected often).
    # But wait, Sinatra helpers are available in the scope.
    # We can inspect the body of the index page to see if it contains the questions.

    it "includes suggested questions in the index page" do
      get "/"
      expect(last_response.body).to include("Summarize this repository")
      expect(last_response.body).to include("Identify potential technical debt")
    end

    it "includes Gemfile-specific questions if Gemfile exists" do
      # We know Gemfile exists in this repo
      get "/"
      expect(last_response.body).to include("Explain the dependencies in Gemfile")
    end
  end
end
