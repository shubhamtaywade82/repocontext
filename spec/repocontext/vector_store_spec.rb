# frozen_string_literal: true

require "spec_helper"

RSpec.describe RepoContext::VectorStore do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil) }
  let(:temp_dir) { Dir.mktmpdir }
  let(:store) { described_class.new(repo_root: temp_dir, logger: logger) }

  after do
    FileUtils.remove_entry(temp_dir)
  end

  describe "#upsert and #find_chunks" do
    it "stores and retrieves chunks" do
      chunks = [
        { text: "chunk 1", embedding: [0.1, 0.2, 0.3] },
        { text: "chunk 2", embedding: [0.4, 0.5, 0.6] }
      ]

      store.upsert("test.rb", 12345, chunks)
      retrieved = store.find_chunks("test.rb")

      expect(retrieved.size).to eq(2)
      expect(retrieved[0][:text]).to eq("chunk 1")
      expect(retrieved[0][:embedding]).to eq([0.1, 0.2, 0.3])
      expect(retrieved[1][:text]).to eq("chunk 2")
    end

    it "updates existing chunks" do
      chunks1 = [{ text: "old", embedding: [1.0] }]
      chunks2 = [{ text: "new", embedding: [2.0] }]

      store.upsert("test.rb", 12345, chunks1)
      store.upsert("test.rb", 12346, chunks2)

      retrieved = store.find_chunks("test.rb")
      expect(retrieved.size).to eq(1)
      expect(retrieved[0][:text]).to eq("new")
    end

    it "returns empty array for non-existent path" do
      expect(store.find_chunks("nonexistent.rb")).to eq([])
    end
  end

  describe "#stored_mtime" do
    it "returns mtime for stored path" do
      chunks = [{ text: "test", embedding: [1.0] }]
      store.upsert("test.rb", 12345, chunks)

      expect(store.stored_mtime("test.rb")).to eq(12345)
    end

    it "returns nil for non-existent path" do
      expect(store.stored_mtime("nonexistent.rb")).to be_nil
    end

    it "updates mtime on upsert" do
      chunks = [{ text: "test", embedding: [1.0] }]
      store.upsert("test.rb", 12345, chunks)
      store.upsert("test.rb", 67890, chunks)

      expect(store.stored_mtime("test.rb")).to eq(67890)
    end
  end

  describe "#count_items" do
    it "counts stored items" do
      chunks1 = [{ text: "a", embedding: [1.0] }, { text: "b", embedding: [2.0] }]
      chunks2 = [{ text: "c", embedding: [3.0] }]

      store.upsert("file1.rb", 1, chunks1)
      store.upsert("file2.rb", 2, chunks2)

      expect(store.count_items).to eq(3)
    end
  end

  describe "WAL mode" do
    it "enables WAL mode for better concurrency" do
      store.upsert("warm.rb", 1, [{ text: "x", embedding: [0.0] }]) # ensure DB exists with WAL
      db_path = File.join(temp_dir, "repocontext.db")
      db = SQLite3::Database.new(db_path)
      journal_mode = db.execute("PRAGMA journal_mode;").first.first
      db.close
      expect(journal_mode.downcase).to eq("wal")
    end
  end
end
