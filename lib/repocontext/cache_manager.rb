# frozen_string_literal: true

module RepoContext
  # Unified caching layer supporting in-memory and Redis backends
  # Provides automatic TTL, cache metrics, and graceful fallback
  class CacheManager
    PERCENT_SCALE = 100

    def initialize(logger: Settings.logger, namespace: "repocontext")
      @log = logger
      @namespace = namespace
      @backend = build_backend
      @metrics = { hits: 0, misses: 0, sets: 0 }
      @metrics_mutex = Mutex.new
    end

    def get(key)
      namespaced_key = namespaced(key)
      value = @backend.get(namespaced_key)

      record_metric(value ? :hits : :misses)
      @log.debug { "cache #{value ? 'HIT' : 'MISS'}: #{key}" } if value || Settings::LOG_LEVEL == "debug"

      value
    rescue StandardError => e
      @log.warn { "cache get failed for #{key}: #{e.message}" }
      nil
    end

    def set(key, value, ttl: Settings::CACHE_TTL_SECONDS)
      namespaced_key = namespaced(key)
      @backend.set(namespaced_key, value, ttl)
      record_metric(:sets)
      @log.debug { "cache SET: #{key} (ttl=#{ttl}s)" }
      value
    rescue StandardError => e
      @log.warn { "cache set failed for #{key}: #{e.message}" }
      value
    end

    def delete(key)
      namespaced_key = namespaced(key)
      @backend.delete(namespaced_key)
      @log.debug { "cache DELETE: #{key}" }
    rescue StandardError => e
      @log.warn { "cache delete failed for #{key}: #{e.message}" }
    end

    def clear
      @backend.clear
      @log.info { "cache cleared for namespace: #{@namespace}" }
    rescue StandardError => e
      @log.warn { "cache clear failed: #{e.message}" }
    end

    def metrics
      @metrics_mutex.synchronize { @metrics.dup }
    end

    def hit_rate
      total = metrics[:hits] + metrics[:misses]
      return 0.0 if total.zero?
      (metrics[:hits].to_f / total * PERCENT_SCALE).round(2)
    end

    private

    def build_backend
      return InMemoryBackend.new(@log) unless Settings::CACHE_ENABLED

      if Settings::REDIS_URL && redis_available?
        @log.info { "cache backend: Redis (#{Settings::REDIS_URL})" }
        RedisBackend.new(Settings::REDIS_URL, @log)
      else
        @log.info { "cache backend: in-memory" }
        InMemoryBackend.new(@log)
      end
    rescue StandardError => e
      @log.warn { "Redis init failed, falling back to in-memory: #{e.message}" }
      InMemoryBackend.new(@log)
    end

    def redis_available?
      require "redis"
      true
    rescue LoadError
      @log.warn { "Redis gem not available, using in-memory cache" }
      false
    end

    def namespaced(key)
      "#{@namespace}:#{key}"
    end

    def record_metric(type)
      @metrics_mutex.synchronize { @metrics[type] += 1 }
    end

    # In-memory cache backend with TTL support
    class InMemoryBackend
      def initialize(logger)
        @store = {}
        @mutex = Mutex.new
        @log = logger
      end

      def get(key)
        @mutex.synchronize do
          entry = @store[key]
          return nil unless entry

          if entry[:expires_at] && Time.now.to_i > entry[:expires_at]
            @store.delete(key)
            return nil
          end

          entry[:value]
        end
      end

      def set(key, value, ttl)
        @mutex.synchronize do
          @store[key] = {
            value: value,
            expires_at: ttl ? Time.now.to_i + ttl : nil
          }
        end
      end

      def delete(key)
        @mutex.synchronize { @store.delete(key) }
      end

      def clear
        @mutex.synchronize { @store.clear }
      end
    end

    # Redis cache backend (optional)
    class RedisBackend
      def initialize(redis_url, logger)
        @log = logger
        @redis = Redis.new(url: redis_url)
      end

      def get(key)
        value = @redis.get(key)
        value ? deserialize(value) : nil
      end

      def set(key, value, ttl)
        serialized = serialize(value)
        if ttl
          @redis.setex(key, ttl, serialized)
        else
          @redis.set(key, serialized)
        end
      end

      def delete(key)
        @redis.del(key)
      end

      def clear
        # Note: This only clears keys matching the namespace pattern
        # Be careful with this in production
        @log.warn { "Redis clear not implemented (requires namespace scanning)" }
      end

      private

      def serialize(value)
        Marshal.dump(value)
      end

      def deserialize(value)
        Marshal.load(value)
      end
    end
  end
end
