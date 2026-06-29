# Ramplitude Ruby SDK — Port Plan

> "Ramplitude" is the name of this Ruby gem. "Amplitude" is the trademark of
> Amplitude, Inc. — this project is not affiliated with or endorsed by them.

Port of the official [Amplitude Python SDK](https://github.com/amplitude/Amplitude-Python)
(cloned to `tmp/Amplitude-Python/`, ~2,500 LOC across 13 modules) to a Ruby gem
that keeps the Python public API recognisable but feels native to Rubyists and
supports pluggable buffering for out-of-process flushing (Redis + Sidekiq).

## 1. Source module map

| Python module          | Responsibility | Ruby counterpart |
| ---------------------- | --- | --- |
| `client.py`            | `Ramplitude` façade: `track / identify / group_identify / set_group / revenue / flush / shutdown / add / remove`. Registers default plugins, hooks `atexit`. | `Ramplitude::Client` |
| `config.py`            | `Config` value object: api_key, flush_queue_size (200), flush_interval_millis (10_000), flush_max_retries (12), min_id_length, server_zone (US/EU), use_batch, server_url, callback, plan, ingestion_metadata, opt_out. Lazy `server_url`, dynamic `flush_queue_size` divider for payload-too-large adaptation. | `Ramplitude::Config` |
| `constants.py`         | SDK name/version, server URLs, identify ops, revenue keys, `PluginType` enum, defaults. | `Ramplitude::Constants` + `Ramplitude::PluginType` |
| `event.py` (1,315 LOC) | `EventOptions` (~40 fields), `BaseEvent`, `IdentifyEvent`, `GroupIdentifyEvent`, `RevenueEvent`, `Identify` (set/set_once/add/append/prepend/pre_insert/post_insert/remove/unset/clear_all), `Revenue` (price/quantity/product_id/receipt/...), `Plan`, `IngestionMetadata`. Wire-format mapping via `EVENT_KEY_MAPPING`. Retry counter, per-event callback. | `Ramplitude::Event::*` |
| `timeline.py`          | Plugin pipeline with three locked stages: BEFORE → ENRICHMENT → DESTINATION. Destinations get a deepcopy. | `Ramplitude::Timeline` |
| `plugin.py`            | `Plugin` ABC, `EventPlugin`, `DestinationPlugin`, `AmplitudeDestinationPlugin`, `ContextPlugin` (stamps time/insert_id/library), `verify_event`. | `Ramplitude::Plugin::*` |
| `storage.py`           | `Storage` ABC, `InMemoryStorage` (ready_queue + delayed buffer with binary-insertion-by-timestamp), capacity cap (20k), exponential retry delay. | `Ramplitude::Sink::*` (renamed) |
| `worker.py`            | `Workers`: consumer thread on a condvar + `ThreadPoolExecutor(16)` posting batches. `flush()` returns a combined Future. | `Ramplitude::Uploader::*` (split out) |
| `http_client.py`       | `HttpClient.post` via `urllib`; `HttpStatus`, rich `Response` with all 400/413/429 field diagnostics. | `Ramplitude::HTTPClient`, `Ramplitude::Response` |
| `processor.py`         | `ResponseProcessor`: maps HTTP outcome to callback / retry / requeue-with-delay (429→30s) / shrink-batch (413) / raise on bad API key. | `Ramplitude::ResponseProcessor` |
| `utils.py`             | `current_milliseconds`, `truncate` (1024 string / 1024 keys). | `Ramplitude::Utils` |
| `exception.py`         | `InvalidAPIKeyError`, `InvalidEventError`. | `Ramplitude::Error` subclasses |

## 2. Behaviour to preserve

1. **Two endpoints** — HTTP V2 (default) and `use_batch=true` → `/batch`, US + EU zones.
2. **Adaptive batching** — on HTTP 413 reduce `flush_queue_size` via an increasing divisor; re-queue.
3. **Delayed retries** — `100 * 2^((retry-1)/2)` ms; 429 throttled events +30s; cap at 12; sink capacity cap 20k.
4. **Pipeline ordering** — BEFORE → ENRICHMENT (may return `nil` to drop) → DESTINATION (deep copy).
5. **Default plugins** — `ContextPlugin` stamps `time`, `insert_id`, `library="amplitude-ruby/<version>"`, plan, ingestion_metadata; `AmplitudeDestinationPlugin` does upload.
6. **Per-event + config-level callbacks** invoked with `(event, code, message)`.
7. **Auto flush on process exit** via `at_exit`.
8. **Identify validation** — numeric-only for `add`, type-checked values for set/append/etc.
9. **Truncation** at 1024 chars / 1024 keys on serialisation.

## 3. Key design adjustment: Sink + Uploader split

Python conflates "where events sit" with "who drains them". For Redis-backed
handoff to Sidekiq/ActiveJob, we split:

### `Ramplitude::Sink` — where events go after the pipeline

```ruby
class Sink
  def push(event, delay_ms: 0); end   # [accepted?, reason_or_nil]
  def pull(max:); end                 # Array<Event> due now
  def pull_all; end                   # drain all
  def size; nil; end                  # optional, for backpressure
  def wait(timeout_ms:); nil; end     # optional; condvar / BRPOP
end
```

Built-in sinks:

| Sink              | Backing                                 | Notes |
| ----------------- | --------------------------------------- | --- |
| `Sink::InMemory`  | array + delayed buffer (port of Python) | Default |
| `Sink::Redis`     | Redis ZSET keyed by ready-at timestamp  | `ZADD` to push, `ZRANGEBYSCORE`+`ZREM` via Lua to pull atomically, `BZPOPMIN` to wait. Payload = `{ payload:, retry: }` JSON so retry counters survive a restart. Capacity cap via `ZCARD`. |
| `Sink::File`      | append-only JSONL                       | Offline/forensic capture |

### `Ramplitude::Uploader` — who drains the sink

| Uploader               | Drains via                        | Use case |
| ---------------------- | --------------------------------- | --- |
| `Uploader::Threaded`   | thread pool, polls sink.wait/pull | Default; matches Python `Workers` |
| `Uploader::Manual`     | nothing; only `flush` sends       | Tests, your own cron |
| `Uploader::Null`       | no-op                             | External job (Sidekiq/ActiveJob) takes over |

### Out-of-process drainer

`Ramplitude::BulkFlusher` reuses `ResponseProcessor` without spawning a consumer
thread — call it from Sidekiq/ActiveJob. On retryable failures it pushes events
back into the sink with the same exponential delay so the next job run picks
them up.

### Wiring examples

```ruby
# A) Default — in-process, in-memory
Ramplitude::Client.new(api_key: KEY)

# B) Redis sink, in-process uploader (durable buffer, same process POSTs)
Ramplitude::Client.new(
  api_key:  KEY,
  sink:     Ramplitude::Sink::Redis.new(redis: Redis.new, key: "amp:events"),
  uploader: Ramplitude::Uploader::Threaded.new,
)

# C) Redis sink, external drainer (web only enqueues; Sidekiq POSTs)
web_client = Ramplitude::Client.new(
  api_key:  KEY,
  sink:     Ramplitude::Sink::Redis.new(redis: $redis, key: "amp:events"),
  uploader: Ramplitude::Uploader::Null.new,
)

class AmplitudeFlushJob
  include Sidekiq::Job
  def perform
    Ramplitude::BulkFlusher.new(
      api_key: ENV.fetch("AMPLITUDE_API_KEY"),
      sink:    Ramplitude::Sink::Redis.new(redis: $redis, key: "amp:events"),
      config:  Ramplitude::Config.new(use_batch: true, flush_queue_size: 1000),
    ).drain(max_batches: 50)
  end
end
```

## 4. Public Ruby API

Same method names as Python; keyword args + block sugar for the common cases.

```ruby
# Client construction
amplitude = Ramplitude::Client.new(api_key: ENV.fetch("AMPLITUDE_API_KEY")) do |c|
  c.flush_queue_size  = 200
  c.flush_interval_ms = 10_000        # renamed from flush_interval_millis
  c.flush_max_retries = 12
  c.server_zone       = :us           # symbols for enums (:us/:eu)
  c.use_batch         = false
  c.on_event          = ->(event, code, message) { ... }
end

# Track — three shapes
amplitude.track("Button Clicked", user_id: "u-123", event_properties: { color: "red" })
amplitude.track("Button Clicked") { |e| e.user_id = "u-123"; e.platform = "web" }
amplitude.track(Ramplitude::Event.new(event_type: "Button Clicked", user_id: "u-123"))

# Identify — fluent or block
amplitude.identify(user_id: "u-123") do |i|
  i.set      :location, "LAX"
  i.set_once :first_seen_at, Time.now.iso8601
  i.add      :login_count, 1
  i.append   :badges, "early-adopter"
end

# Groups
amplitude.set_group("org_id", "15", user_id: "u-123")
amplitude.group_identify("org_id", "15", user_id: "u-123") { |i| i.set :locale, "en-us" }

# Revenue
amplitude.revenue(user_id: "u-123",
                  price: 3.99, quantity: 3, product_id: "sku-42",
                  receipt: "...", revenue_type: "purchase")

# Lifecycle
amplitude.flush.wait
amplitude.shutdown

# Plugins — class form (Python parity) + block sugar
amplitude.before     { |e| e.platform ||= "web"; e }
amplitude.enrich     { |e| e.event_properties&.delete(:email); e }
amplitude.destination(MyExporter.new)

# Module-level singleton for one-project apps
Ramplitude.configure { |c| c.api_key = "..."; c.server_zone = :eu }
Ramplitude.track("Page Viewed", user_id: "u-123")
```

### Naming changes (Python → Ruby)

| Python                  | Ruby                                  | Reason |
| ----------------------- | ------------------------------------- | --- |
| `flush_interval_millis` | `flush_interval_ms`                   | Rubyists abbreviate |
| `callback` (config)     | `on_event`                            | Idiomatic event-handler |
| `server_zone="US"`      | `server_zone: :us`                    | Symbols for enums |
| `Identify().set("k",v)` | `Identify.new.set(:k, v)`             | Symbols preferred, strings accepted |
| `storage_provider`      | `sink:`                               | Clarifies role split |
| `EventOptions(...)`     | keyword args on `track`/etc.          | Skip the ceremony for the 90% case |
| `client.add(plugin)`    | `add(plugin)` + `before/enrich/destination { }` | Block sugar for one-liners |

## 5. Step-by-step

0. **Gem skeleton** — `bundle gem amplitude-analytics`, Ruby 3.0+, RSpec, RuboCop,
   Zeitwerk, GitHub Actions, MIT licence.
1. **Constants & errors** — translate `constants.py`; `PluginType` as symbols.
2. **Utils** — `current_milliseconds`, recursive `truncate`.
3. **Value objects** — `Plan`, `IngestionMetadata`, `EventOptions`, `BaseEvent`,
   `IdentifyEvent`, `GroupIdentifyEvent`, `RevenueEvent`, `Identify`, `Revenue`.
   Replace Python kwargs explosion with keyword args + `EVENT_KEY_MAPPING` for
   wire serialisation via `to_h`.
4. **Config** — `attr_accessor`s, defaults match Python, `server_url` derived
   from zone + `use_batch`, private `_flush_size_divider` for 413 adaptation.
5. **Sink interface** + `Sink::InMemory` (port of Python `InMemoryStorage`
   algorithm: `ready_queue` + binary-inserted delayed buffer, `Mutex` +
   `ConditionVariable`).
6. **Sink::Redis** — soft dep on `redis` gem; Lua script for atomic pull;
   `BZPOPMIN` for wait; payload includes retry counter.
7. **HTTP client** — `Net::HTTP` with keep-alive; `Ramplitude::Response` parses
   `events_with_*`, `throttled_events`, `exceeded_daily_quota_*`.
8. **Uploader interface** + `Uploader::Threaded` (fixed thread pool + consumer
   thread on `sink.wait`), `Uploader::Manual`, `Uploader::Null`.
9. **ResponseProcessor** — verbatim port; pure logic.
10. **Plugins & timeline** — `Plugin::Base`, `EventPlugin`, `DestinationPlugin`,
    `AmplitudeDestinationPlugin`, `ContextPlugin`. Deep copy for destinations.
11. **BulkFlusher** — for out-of-process drainers (Sidekiq/ActiveJob).
12. **Client façade** — wires defaults, `at_exit { shutdown }`, block config,
    `Ramplitude.configure` singleton.
13. **Tests** — mirror `src/test/*.py` 1:1 in RSpec; WebMock for HTTP;
    Redis sink tests behind a `REDIS_URL` env guard.
14. **Examples** — Sinatra app; Rails initializer + `AmplitudeFlushJob` Sidekiq
    example; plain-script example.
15. **Release** — RubyGems as `amplitude-analytics` (mirrors Python name).

## 6. Gem layout

```
amplitude-analytics/
├── amplitude-analytics.gemspec
├── Gemfile
├── README.md
├── LICENSE.txt
├── lib/
│   └── amplitude/
│       ├── version.rb
│       ├── constants.rb
│       ├── errors.rb
│       ├── utils.rb
│       ├── config.rb
│       ├── event.rb           # EventOptions, BaseEvent, IdentifyEvent, ...
│       ├── identify.rb
│       ├── revenue.rb
│       ├── plan.rb            # Plan, IngestionMetadata
│       ├── timeline.rb
│       ├── plugin.rb          # Base + EventPlugin + DestinationPlugin
│       ├── plugins/
│       │   ├── context.rb
│       │   └── amplitude_destination.rb
│       ├── sink.rb            # base
│       ├── sinks/
│       │   ├── in_memory.rb
│       │   ├── redis.rb
│       │   └── file.rb
│       ├── uploader.rb        # base
│       ├── uploaders/
│       │   ├── threaded.rb
│       │   ├── manual.rb
│       │   └── null.rb
│       ├── http_client.rb
│       ├── response.rb
│       ├── response_processor.rb
│       ├── bulk_flusher.rb
│       └── client.rb
├── lib/amplitude.rb           # top-level + Ramplitude.configure / .track
└── spec/
    ├── spec_helper.rb
    └── (mirrors src/test/*)
```
