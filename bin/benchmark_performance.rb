#!/usr/bin/env ruby
# frozen_string_literal: true

# Performance benchmark script for RepoContext optimizations
# Usage: bundle exec ruby bin/benchmark_performance.rb

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))
require "repocontext"
require "benchmark"
require "json"

class PerformanceBenchmark
  def initialize
    @log = RepoContext::Settings.logger
    @results = {}
  end

  def run_all
    puts "\n" + "=" * 60
    puts "RepoContext Performance Benchmark"
    puts "=" * 60

    benchmark_cache_performance
    benchmark_vector_store
    benchmark_embedding_context

    print_summary
  end

  private

  def benchmark_cache_performance
    puts "\n--- Cache Performance ---"
    cache = RepoContext::CacheManager.new(namespace: "bench")

    # Warm-up cache
    1000.times { |i| cache.set("key_#{i}", "value_#{i}") }

    # Benchmark cache hits
    hit_time = Benchmark.realtime do
      1000.times { |i| cache.get("key_#{i}") }
    end

    # Benchmark cache misses
    miss_time = Benchmark.realtime do
      1000.times { |i| cache.get("missing_key_#{i}") }
    end

    puts "1000 cache hits:   #{(hit_time * 1000).round(2)}ms (#{(hit_time / 10).round(5)}ms/op)"
    puts "1000 cache misses: #{(miss_time * 1000).round(2)}ms (#{(miss_time / 10).round(5)}ms/op)"
    puts "Cache hit rate: #{cache.hit_rate}%"

    @results[:cache_hit_time] = hit_time
    @results[:cache_miss_time] = miss_time
    @results[:cache_hit_rate] = cache.hit_rate
  end

  def benchmark_vector_store
    puts "\n--- Vector Store Performance ---"

    store = RepoContext::VectorStore.new(
      repo_root: RepoContext::Settings::REPO_ROOT,
      logger: @log
    )

    # Benchmark insertions
    test_chunks = 100.times.map do |i|
      {
        text: "Sample chunk text #{i}" * 10,
        embedding: Array.new(768) { rand }
      }
    end

    insert_time = Benchmark.realtime do
      store.upsert("benchmark_test.rb", Time.now.to_i, test_chunks)
    end

    # Benchmark lookups
    lookup_time = Benchmark.realtime do
      100.times { store.find_chunks("benchmark_test.rb") }
    end

    # Benchmark mtime checks
    mtime_time = Benchmark.realtime do
      1000.times { store.stored_mtime("benchmark_test.rb") }
    end

    puts "Insert 100 chunks: #{(insert_time * 1000).round(2)}ms"
    puts "100 lookups:       #{(lookup_time * 1000).round(2)}ms (#{(lookup_time / 100 * 1000).round(2)}ms/op)"
    puts "1000 mtime checks: #{(mtime_time * 1000).round(2)}ms (#{(mtime_time / 1000 * 1000).round(3)}ms/op)"

    @results[:db_insert_time] = insert_time
    @results[:db_lookup_time] = lookup_time
    @results[:db_mtime_time] = mtime_time

    # Cleanup
    store.upsert("benchmark_test.rb", 0, [])
  end

  def benchmark_embedding_context
    puts "\n--- Embedding Context Performance ---"

    unless RepoContext::Settings::EMBED_CONTEXT_ENABLED
      puts "Embeddings disabled, skipping..."
      return
    end

    client = RepoContext::OllamaClientFactory.build(
      model: RepoContext::Settings::OLLAMA_MODEL,
      temperature: 0.0,
      timeout: RepoContext::Settings::OLLAMA_TIMEOUT
    )

    builder = RepoContext::EmbeddingContextBuilder.new(
      client: client,
      repo_root: RepoContext::Settings::REPO_ROOT,
      candidate_paths_source: -> { ["README.md"] },
      logger: @log
    )

    test_question = "What is this repository about?"

    # First run (cold cache)
    cold_time = Benchmark.realtime do
      builder.context_for_question(test_question, max_chars: 2000)
    end

    # Second run (warm cache)
    warm_time = Benchmark.realtime do
      builder.context_for_question(test_question, max_chars: 2000)
    end

    speedup = ((cold_time - warm_time) / cold_time * 100).round(1)

    puts "Cold query: #{(cold_time * 1000).round(2)}ms"
    puts "Warm query: #{(warm_time * 1000).round(2)}ms"
    puts "Cache speedup: #{speedup}%"

    @results[:embed_cold_time] = cold_time
    @results[:embed_warm_time] = warm_time
    @results[:embed_speedup] = speedup
  rescue StandardError => e
    puts "Error benchmarking embeddings: #{e.message}"
    puts "Make sure Ollama is running and the embedding model is available."
  end

  def print_summary
    puts "\n" + "=" * 60
    puts "Summary"
    puts "=" * 60
    puts JSON.pretty_generate(@results)
    puts "\nBenchmark complete!"
  end
end

if __FILE__ == $PROGRAM_NAME
  benchmark = PerformanceBenchmark.new
  benchmark.run_all
end
