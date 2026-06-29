# frozen_string_literal: true

require "json"

module Ramplitude
  module Sinks
    # Redis-backed sink. Stores events in a ZSET keyed by their ready-at
    # timestamp (ms since epoch). `push` does ZADD; `pull` atomically reads
    # then removes due events via a Lua script; `wait` uses BZPOPMIN.
    #
    # Payload schema (per ZSET member):
    #   {"e": <event.to_h>, "r": <retry_count>}
    # Stored with a uniqueness suffix (`_s`) so two identical events coexist.
    #
    # Accepts either a `Redis` client or a `ConnectionPool<Redis>` —
    # detected by whether the object responds to `:with`. With a pool every
    # command checks out / returns a connection via `.with { |r| ... }`.
    class Redis < Sink
      PULL_LUA = <<~LUA
        local key   = KEYS[1]
        local now   = tonumber(ARGV[1])
        local max   = tonumber(ARGV[2])
        local items = redis.call('ZRANGEBYSCORE', key, '-inf', now, 'LIMIT', 0, max)
        if #items > 0 then
          redis.call('ZREM', key, unpack(items))
        end
        return items
      LUA

      # Wraps a bare Redis client so it satisfies the ConnectionPool#with API.
      # Lets the sink treat pooled and unpooled clients uniformly.
      class NullPool
        def initialize(client) = (@client = client)
        def with               = yield(@client)
      end

      def initialize(redis:, key: "amplitude:events", capacity: Constants::MAX_BUFFER_CAPACITY)
        @pool      = redis.respond_to?(:with) ? redis : NullPool.new(redis)
        @key       = key
        @capacity  = capacity
        @sha       = nil
        @seq       = 0
        @seq_mutex = Mutex.new
      end

      def push(event, delay_ms: 0)
        return [false, "Event reached max retry #{max_retries}"] if event.retry_count >= max_retries
        if event.retry_count > 0 && size >= @capacity
          return [false, "Sink full; retry temporarily disabled"]
        end

        total_delay = delay_ms + retry_delay(event.retry_count)
        ts = Utils.current_milliseconds + total_delay
        payload = serialize(event)
        with_redis { |r| r.zadd(@key, ts, payload) }
        [true, nil]
      end

      def pull(max:)
        now = Utils.current_milliseconds
        items = eval_pull(now, max)
        items.map { |raw| deserialize(raw) }
      end

      def pull_all
        all = with_redis do |r|
          fetched = r.zrange(@key, 0, -1)
          r.del(@key)
          fetched
        end
        Array(all).map { |raw| deserialize(raw) }
      end

      def size = with_redis { |r| r.zcard(@key) }

      # BZPOPMIN blocks until the lowest-score element is available; we
      # immediately reinsert it (we only wanted the wake-up signal).
      def wait(timeout_ms:)
        timeout_s = (timeout_ms / 1000.0).ceil
        timeout_s = 1 if timeout_s < 1
        with_redis do |r|
          res = r.bzpopmin(@key, timeout_s)
          if res
            _key, member, score = res
            r.zadd(@key, score, member)
          end
        end
        nil
      end

      private

      # Checks out a connection. Every Redis command in this class goes
      # through here so the pooled / unpooled distinction lives only at
      # construction time.
      def with_redis(&block) = @pool.with(&block)

      def eval_pull(now, max)
        with_redis do |r|
          begin
            @sha ||= r.script(:load, PULL_LUA)
            r.evalsha(@sha, keys: [@key], argv: [now, max])
          rescue ::Redis::CommandError => e
            raise unless e.message.include?("NOSCRIPT")
            @sha = r.script(:load, PULL_LUA)
            retry
          end
        end
      end

      def serialize(event)
        seq = @seq_mutex.synchronize { @seq += 1 }
        JSON.generate("e" => event.to_h, "r" => event.retry_count, "_s" => seq)
      end

      def deserialize(raw)
        h = JSON.parse(raw)
        wire = h.fetch("e")
        kwargs = Event::EVENT_KEY_MAPPING.each_with_object({}) do |(attr, wire_key), acc|
          acc[attr] = wire[wire_key] if wire.key?(wire_key)
        end
        klass = case wire["event_type"]
                when Constants::IDENTIFY_EVENT       then IdentifyEvent
                when Constants::GROUP_IDENTIFY_EVENT then GroupIdentifyEvent
                when Constants::AMP_REVENUE_EVENT    then RevenueEvent
                else Event
                end
        ev = klass.new(**kwargs)
        ev.retry_count = h.fetch("r", 0)
        ev
      end

      def retry_delay(n) = n <= 0 ? 0 : 100 * (2 ** ((n - 1) / 2))
    end
  end
end
