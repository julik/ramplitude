# frozen_string_literal: true

require_relative "test_helper"

class SmokeTest < Minitest::Test
  def test_public_api_surface
    assert_kind_of String, Ramplitude::VERSION
    assert defined?(Ramplitude::Client)
    assert defined?(Ramplitude::Sink)
    assert defined?(Ramplitude::Sinks::InMemory)
    assert defined?(Ramplitude::Sinks::File)
    assert defined?(Ramplitude::Uploader)
    assert defined?(Ramplitude::Uploaders::Threaded)
    assert defined?(Ramplitude::Uploaders::Manual)
    assert defined?(Ramplitude::Uploaders::Null)
    assert defined?(Ramplitude::BulkFlusher)
  end
end

class IdentifyTest < Minitest::Test
  def test_records_set_and_add_operations
    i = Ramplitude::Identify.new.set(:city, "LAX").add(:logins, 1)
    assert_equal({ "city" => "LAX" }, i.user_properties["$set"])
    assert_equal({ "logins" => 1 }, i.user_properties["$add"])
  end

  def test_rejects_non_numeric_add
    assert_raises(Ramplitude::InvalidEventError) do
      Ramplitude::Identify.new.add(:x, "nope")
    end
  end

  def test_clear_all_locks_out_other_ops
    i = Ramplitude::Identify.new.clear_all
    i.set(:city, "LAX")
    assert_equal({ "$clearAll" => "-" }, i.user_properties)
  end

  def test_valid_only_when_non_empty
    refute Ramplitude::Identify.new.valid?
    assert Ramplitude::Identify.new.set(:k, 1).valid?
  end
end

class EventTest < Minitest::Test
  def test_round_trip_to_wire_format
    e = Ramplitude::Event.new(
      event_type: "Click",
      user_id:    "u-1",
      event_properties: { color: "red" },
    )
    h = e.to_h
    assert_equal "Click", h["event_type"]
    assert_equal "u-1",   h["user_id"]
    assert_equal({ color: "red" }, h["event_properties"])
  end

  def test_indexer_access
    e = Ramplitude::Event.new(event_type: "X")
    e[:user_id] = "u-2"
    assert_equal "u-2", e[:user_id]
  end

  def test_omits_nil_fields
    e = Ramplitude::Event.new(event_type: "X")
    refute_includes e.to_h, "user_id"
  end
end

class InMemorySinkTest < Minitest::Test
  def setup
    @cfg = Ramplitude::Config.new(api_key: "x", flush_queue_size: 10)
    @sink = Ramplitude::Sinks::InMemory.new
    @sink.setup(@cfg)
  end

  def test_push_and_pull_all
    ev = Ramplitude::Event.new(event_type: "X", user_id: "u")
    accepted, msg = @sink.push(ev)
    assert accepted
    assert_nil msg
    assert_equal 1, @sink.size
    assert_equal 1, @sink.pull_all.size
    assert_equal 0, @sink.size
  end

  def test_pull_with_max
    3.times { |i| @sink.push(Ramplitude::Event.new(event_type: "X", user_id: "u#{i}")) }
    batch = @sink.pull(max: 2)
    assert_equal 2, batch.size
    assert_equal 1, @sink.size
  end

  def test_max_retries_rejection
    ev = Ramplitude::Event.new(event_type: "X", user_id: "u")
    ev.retry_count = @cfg.flush_max_retries
    accepted, msg = @sink.push(ev)
    refute accepted
    assert_match(/max retry/, msg)
  end
end

class ConfigTest < Minitest::Test
  def test_server_url_resolves_from_zone_and_batch
    cfg = Ramplitude::Config.new(api_key: "x", server_zone: :us, use_batch: false)
    assert_equal "https://api2.amplitude.com/2/httpapi", cfg.server_url

    cfg.use_batch = true
    assert_equal "https://api2.amplitude.com/batch", cfg.server_url

    cfg.server_zone = :eu
    assert_equal "https://api.eu.amplitude.com/batch", cfg.server_url
  end

  def test_flush_size_divider_shrinks_batch
    cfg = Ramplitude::Config.new(api_key: "x", flush_queue_size: 200)
    assert_equal 200, cfg.flush_queue_size
    cfg._increase_flush_divider
    assert_equal 100, cfg.flush_queue_size
    cfg._reset_flush_divider
    assert_equal 200, cfg.flush_queue_size
  end

  def test_valid_requires_api_key
    refute Ramplitude::Config.new.valid?
    assert Ramplitude::Config.new(api_key: "x").valid?
  end
end

class UtilsTest < Minitest::Test
  def test_truncate_long_strings
    s = "x" * (Ramplitude::Constants::MAX_STRING_LENGTH + 10)
    assert_equal Ramplitude::Constants::MAX_STRING_LENGTH, Ramplitude::Utils.truncate(s).length
  end

  def test_truncate_drops_oversized_hash
    big = (0..Ramplitude::Constants::MAX_PROPERTY_KEYS).each_with_object({}) { |i, h| h[i.to_s] = i }
    assert_equal({}, Ramplitude::Utils.truncate(big))
  end

  def test_current_milliseconds_is_int
    assert_kind_of Integer, Ramplitude::Utils.current_milliseconds
  end
end
