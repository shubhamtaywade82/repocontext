# frozen_string_literal: true

require "spec_helper"

RSpec.describe RepoContext::CacheManager do
  let(:logger) { instance_double(Logger, debug: nil, info: nil, warn: nil) }
  let(:cache) { described_class.new(logger: logger, namespace: "test") }

  describe "#set and #get" do
    it "stores and retrieves values" do
      cache.set("key1", "value1")
      expect(cache.get("key1")).to eq("value1")
    end

    it "returns nil for missing keys" do
      expect(cache.get("nonexistent")).to be_nil
    end

    it "supports complex data types" do
      data = { foo: "bar", baz: [1, 2, 3] }
      cache.set("complex", data)
      expect(cache.get("complex")).to eq(data)
    end
  end

  describe "#delete" do
    it "removes cached values" do
      cache.set("key1", "value1")
      cache.delete("key1")
      expect(cache.get("key1")).to be_nil
    end
  end

  describe "#clear" do
    it "removes all cached values" do
      cache.set("key1", "value1")
      cache.set("key2", "value2")
      cache.clear
      expect(cache.get("key1")).to be_nil
      expect(cache.get("key2")).to be_nil
    end
  end

  describe "TTL support" do
    it "respects TTL for cache entries" do
      cache.set("short_lived", "value", ttl: 10)
      expect(cache.get("short_lived")).to eq("value")
      # Verify it's still there (not expired yet)
      sleep 0.1
      expect(cache.get("short_lived")).to eq("value")
    end

    it "supports entries without TTL" do
      cache.set("permanent", "value", ttl: nil)
      expect(cache.get("permanent")).to eq("value")
    end
  end

  describe "metrics" do
    it "tracks cache hits and misses" do
      cache.set("key1", "value1")

      cache.get("key1")  # hit
      cache.get("missing")  # miss
      cache.get("key1")  # hit

      metrics = cache.metrics
      expect(metrics[:hits]).to eq(2)
      expect(metrics[:misses]).to eq(1)
      expect(metrics[:sets]).to eq(1)
    end

    it "calculates hit rate" do
      cache.set("key1", "value1")

      3.times { cache.get("key1") }  # 3 hits
      1.times { cache.get("missing") }  # 1 miss

      expect(cache.hit_rate).to eq(75.0)
    end

    it "returns 0 hit rate when no operations" do
      expect(cache.hit_rate).to eq(0.0)
    end
  end

  describe "namespace isolation" do
    it "isolates keys by namespace" do
      cache1 = described_class.new(logger: logger, namespace: "ns1")
      cache2 = described_class.new(logger: logger, namespace: "ns2")

      cache1.set("key", "value1")
      cache2.set("key", "value2")

      expect(cache1.get("key")).to eq("value1")
      expect(cache2.get("key")).to eq("value2")
    end
  end
end
