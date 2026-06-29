# Ramplitude

A Ruby gem that posts events to [Amplitude](https://amplitude.com/) — a port of
the official [Amplitude Python SDK](https://github.com/amplitude/Amplitude-Python),
with a pluggable **Sink / Uploader** split so events can be buffered to Redis
(or any backend you wire up) and flushed from a background job.

> **Trademark notice.** "Amplitude" and the Amplitude logo are trademarks of
> Amplitude, Inc. This project is an independent, unofficial Ruby client and
> is **not** affiliated with, endorsed by, or sponsored by Amplitude, Inc. The
> name "Ramplitude" is a portmanteau ("Ruby" + "Amplitude") chosen to make
> that relationship clear. If you want the official SDK, see
> <https://amplitude.com/docs/sdks>.

> Status: scaffold / WIP. Not yet shipped to RubyGems.

## Install

```ruby
gem "ramplitude"
# Optional, only if you use the Redis sink:
gem "redis"
```

## Quick start (in-process, in-memory — Python-equivalent default)

```ruby
require "ramplitude"

amplitude = Ramplitude::Client.new(api_key: ENV.fetch("AMPLITUDE_API_KEY"))

amplitude.track("Button Clicked", user_id: "u-1", event_properties: { color: "red" })
amplitude.identify(user_id: "u-1") { |i| i.set(:plan, "pro").add(:logins, 1) }
amplitude.revenue(user_id: "u-1", price: 9.99, quantity: 1, product_id: "sku-42")

amplitude.flush.wait
amplitude.shutdown   # also runs in at_exit
```

## Buffering to Redis + bulk upload from an ActiveJob

For Rails apps that don't want any HTTP I/O on the request path: web workers
push events into a Redis ZSET, and a periodic ActiveJob drains the buffer to
Amplitude in batches.

### 1. Initializer — point the client at Redis, disable in-process upload

```ruby
# config/initializers/ramplitude.rb
require "ramplitude"
require "connection_pool"

# Use a pool so concurrent web threads don't fight over a single Redis socket.
# Ramplitude::Sinks::Redis accepts either a bare Redis client or a
# ConnectionPool — it auto-detects via `respond_to?(:with)`.
REDIS_POOL = ConnectionPool.new(size: 10, timeout: 5) do
  Redis.new(url: ENV.fetch("REDIS_URL"))
end

Ramplitude.configure do |c|
  c.api_key   = ENV.fetch("AMPLITUDE_API_KEY")
  c.sink      = Ramplitude::Sinks::Redis.new(redis: REDIS_POOL, key: "ramp:events")
  c.uploader  = Ramplitude::Uploaders::Null.new   # web processes don't drain
  c.use_batch = true                              # use Amplitude's /batch endpoint
end
```

### 2. Track from controllers / models / wherever

```ruby
class CheckoutsController < ApplicationController
  def create
    # ... your business logic ...
    Ramplitude.track("Checkout Completed",
                     user_id: current_user.id.to_s,
                     event_properties: { cents: @order.total_cents })
    head :created
  end
end
```

Calls return immediately — `track` only does `ZADD` to Redis. No HTTP, no
background threads in the web process.

### 3. ActiveJob that drains the buffer

```ruby
# app/jobs/ramplitude_flush_job.rb
class RamplitudeFlushJob < ApplicationJob
  queue_as :ramplitude

  # Idempotent: BulkFlusher pulls batches atomically from Redis (Lua) and
  # re-pushes any events that fail with retryable errors. Safe to run
  # concurrently — Lua pulls don't double-deliver.
  def perform(max_batches: 50)
    Ramplitude::BulkFlusher.new(
      api_key: ENV.fetch("AMPLITUDE_API_KEY"),
      sink:    Ramplitude::Sinks::Redis.new(redis: REDIS_POOL, key: "ramp:events"),
      config:  Ramplitude::Config.new(use_batch: true, flush_queue_size: 1000),
    ).drain(max_batches: max_batches)
  end
end
```

### 4. Schedule it

Pick whatever scheduler your app already uses. Every minute is usually plenty
for analytics traffic; tune up if your queue grows.

```ruby
# With solid_queue / good_job recurring tasks (config/recurring.yml):
production:
  flush_ramplitude:
    class: RamplitudeFlushJob
    schedule: "every 60 seconds"

# Or with whenever (config/schedule.rb):
every 1.minute do
  runner "RamplitudeFlushJob.perform_later"
end

# Or sidekiq-cron, sidekiq-scheduler, etc.
```

### Why this shape

- **No HTTP on the request path.** `ZADD` to Redis is sub-millisecond; web
  workers stay responsive even if Amplitude is slow or down.
- **Survives crashes.** Events live in Redis until they're successfully
  posted; a process restart mid-batch loses nothing.
- **Same retry semantics as the in-process uploader.** `BulkFlusher` reuses
  `Ramplitude::ResponseProcessor`, so HTTP 413 batch-shrinking, HTTP 429
  throttling (with the 30 s extra delay), and exponential backoff for 5xx
  all behave identically. Retry counters are stored alongside the event in
  Redis, so they survive the handoff.
- **One Redis connection per command.** With a `ConnectionPool`, every Redis
  call uses `.with` internally — no implicit single-socket bottleneck.

## Threading

The gem does **not** spawn background threads unless you actually emit an
event with the default `Uploaders::Threaded`. Specifically:

| Action                                                         | Threads spawned? |
| -------------------------------------------------------------- | --- |
| `Ramplitude::Client.new(api_key: ...)`                         | No |
| `client.flush` when nothing has been tracked                   | No |
| Process exit (`at_exit { shutdown }`) with nothing tracked     | No |
| First `track` / `identify` / `revenue` / `set_group` call      | **Yes** — 1 consumer + 4 workers |

The 5 threads belong to the default `Uploaders::Threaded` (mirrors the Python
SDK's `Workers`): one consumer thread waits on the sink, four worker threads
POST batches in parallel. Tune the pool with
`Uploaders::Threaded.new(pool_size: N)`.

### Opting out of background threads

```ruby
# A) Manual: you call flush yourself; no background activity.
Ramplitude::Client.new(
  api_key:  KEY,
  uploader: Ramplitude::Uploaders::Manual.new,
)

# B) Null: nothing drains in this process. Pair with a durable sink (Redis)
#    and a separate worker that runs Ramplitude::BulkFlusher.
Ramplitude::Client.new(
  api_key:  KEY,
  sink:     Ramplitude::Sinks::Redis.new(redis: $redis, key: "ramp:events"),
  uploader: Ramplitude::Uploaders::Null.new,
)
```

`Sinks::InMemory` itself uses a `Mutex` + `ConditionVariable` for thread-safe
buffering but does not own a thread.

## Plugins

```ruby
amplitude.before  { |e| e.platform ||= "web"; e }
amplitude.enrich  { |e| e.event_properties&.delete(:email); e }
```

## Layout

See `llm/plans/port-plan.md` for the full module map and porting plan.
