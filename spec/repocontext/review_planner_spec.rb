# frozen_string_literal: true

require "spec_helper"

RSpec.describe RepoContext::ReviewPlanner do
  let(:logger) { instance_double(Logger, info: nil, warn: nil) }
  let(:client) { instance_double("Ollama::Client") }
  let(:model) { "test-model" }
  let(:planner) { described_class.new(client: client, model: model, logger: logger) }

  describe "#next_step" do
    context "when candidate_paths is empty" do
      it "returns a done step" do
        state = RepoContext::ReviewState.new(request_paths: [], focus: "naming")
        step = planner.next_step(state, [])

        expect(step.done?).to be true
        expect(step.reasoning).to eq("No files to review")
      end
    end

    context "when all paths are already reviewed" do
      it "returns a done step" do
        state = RepoContext::ReviewState.new(
          request_paths: ["lib/foo.rb"],
          focus: "naming",
          reviewed_paths: ["lib/foo.rb"]
        )
        step = planner.next_step(state, ["lib/foo.rb"])

        expect(step.done?).to be true
        expect(step.reasoning).to eq("All candidates reviewed")
      end
    end

    context "when client returns review_file with target" do
      it "returns a review_file step with target and reasoning" do
        state = RepoContext::ReviewState.new(request_paths: ["lib/foo.rb"], focus: "naming")
        allow(client).to receive(:generate).and_return(
          "done" => false,
          "next_action" => "review_file",
          "target" => "lib/foo.rb",
          "reasoning" => "Check naming"
        )

        step = planner.next_step(state, ["lib/foo.rb"])

        expect(step.done?).to be false
        expect(step.review_file?).to be true
        expect(step.target).to eq("lib/foo.rb")
        expect(step.reasoning).to eq("Check naming")
      end
    end

    context "when client returns done" do
      it "returns a done step" do
        state = RepoContext::ReviewState.new(request_paths: ["lib/foo.rb"], focus: "naming")
        allow(client).to receive(:generate).and_return(
          "done" => true,
          "next_action" => "done",
          "target" => "",
          "reasoning" => "Finished"
        )

        step = planner.next_step(state, ["lib/foo.rb"])

        expect(step.done?).to be true
        expect(step.reasoning).to eq("Finished")
      end
    end

    context "when client raises Ollama::Error" do
      it "returns fallback step with first remaining file" do
        state = RepoContext::ReviewState.new(request_paths: ["lib/foo.rb", "lib/bar.rb"], focus: "naming")
        allow(client).to receive(:generate).and_raise(Ollama::Error.new("Connection refused"))

        step = planner.next_step(state, ["lib/foo.rb", "lib/bar.rb"])

        expect(step.review_file?).to be true
        expect(step.target).to eq("lib/foo.rb")
        expect(step.reasoning).to eq("fallback")
      end
    end
  end

  describe "PLAN_PATHS_LIMIT" do
    it "limits paths included in prompt" do
      expect(described_class::PLAN_PATHS_LIMIT).to eq(40)
    end
  end
end
