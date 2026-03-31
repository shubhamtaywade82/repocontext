# frozen_string_literal: true

require "spec_helper"

RSpec.describe RepoContext::ContextBuilder do
  let(:logger) { instance_double(Logger, info: nil, warn: nil, debug: nil) }
  let(:discovery_selector) { instance_double(RepoContext::DiscoveryPathSelector, candidate_paths: [], pick_paths: []) }
  let(:repo_root) { File.expand_path("../..", __dir__) }

  before do
    stub_const("RepoContext::Settings::REPO_ROOT", repo_root)
    stub_const("RepoContext::Settings::REFERENCE_FILES", %w[README.md])
    stub_const("RepoContext::Settings::FALLBACK_CONTEXT_FILES", %w[Gemfile])
    stub_const("RepoContext::Settings::CONTEXT_MAX_CHARS", 35_000)
    stub_const("RepoContext::Settings::DISCOVERY_AGENT_ENABLED", false)
  end

  describe "path security" do
    subject(:builder) { described_class.new(discovery_selector: discovery_selector, embedding_builder: nil, logger: logger) }

    it "rejects path traversal in repo_path" do
      path = builder.send(:repo_path, "../../etc/passwd")
      expect(path).to be_nil
    end

    it "rejects empty relative path" do
      expect(builder.send(:repo_path, "")).to be_nil
      expect(builder.send(:repo_path, nil)).to be_nil
    end

    it "returns expanded path for path under repo root" do
      path = builder.send(:repo_path, "lib/repocontext.rb")
      expect(path).to eq(File.expand_path(File.join(repo_root, "lib/repocontext.rb")))
    end
  end
end
