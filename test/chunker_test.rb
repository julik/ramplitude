# frozen_string_literal: true

require "test_helper"

module Ramplitude
  class ChunkerTest < Minitest::Test
    def event(payload = {})
      Event.new(event_type: "t", user_id: "u", event_properties: payload)
    end

    def parse_chunk(body)
      JSON.parse(body)
    end

    def test_yields_single_chunk_when_everything_fits
      chunker = Chunker.new(max_body_bytes: 10_000, max_events_per_batch: 100, max_event_bytes: 1024)
      events = Array.new(5) { event(i: _1) }

      chunks = chunker.each_chunk(events, api_key: "K").to_a
      assert_equal 1, chunks.size
      body, batch = chunks.first
      assert_equal 5, batch.size
      parsed = parse_chunk(body)
      assert_equal "K", parsed["api_key"]
      assert_equal 5, parsed["events"].size
    end

    def test_splits_when_event_count_cap_hit
      chunker = Chunker.new(max_body_bytes: 1_000_000, max_events_per_batch: 3, max_event_bytes: 1024)
      events = Array.new(7) { event(i: _1) }

      chunks = chunker.each_chunk(events, api_key: "K").to_a
      assert_equal [3, 3, 1], chunks.map { |_body, b| b.size }
    end

    def test_splits_when_body_size_cap_hit
      # ~200 byte events, budget only fits ~2 per chunk after envelope.
      big = "x" * 180
      chunker = Chunker.new(max_body_bytes: 500, max_events_per_batch: 1000, max_event_bytes: 1024)
      events = Array.new(6) { event(blob: big) }

      chunks = chunker.each_chunk(events, api_key: "K").to_a
      # All chunk bodies must be under the budget.
      chunks.each { |body, _| assert_operator body.bytesize, :<=, 500 }
      # All events accounted for.
      total = chunks.sum { |_, b| b.size }
      assert_equal 6, total
      # Should actually split (not one giant chunk).
      assert_operator chunks.size, :>, 1
    end

    def test_body_is_valid_json_with_options
      chunker = Chunker.new(max_body_bytes: 10_000, max_events_per_batch: 100, max_event_bytes: 1024)
      body, = chunker.each_chunk([event(i: 1)], api_key: "K", options: { "min_id_length" => 3 }).to_a.first
      parsed = parse_chunk(body)
      assert_equal({ "min_id_length" => 3 }, parsed["options"])
      assert_equal 1, parsed["events"].size
      assert_equal "K", parsed["api_key"]
    end

    def test_oversize_event_yielded_solo
      chunker = Chunker.new(max_body_bytes: 10_000, max_events_per_batch: 100, max_event_bytes: 50)
      normal = event(i: 1)
      giant  = event(blob: "y" * 500)
      chunks = chunker.each_chunk([normal, giant, normal], api_key: "K").to_a

      # Middle chunk is the solo oversized event; server-side 413 handling will
      # drop it via ResponseProcessor.
      assert_equal [1, 1, 1], chunks.map { |_, b| b.size }
      assert_equal [giant], chunks[1].last
    end

    def test_default_chunkers_have_documented_limits
      v2 = Chunkers::HttpV2.new
      assert_equal 1 * 1024 * 1024, v2.max_body_bytes
      assert_equal 32 * 1024, v2.max_event_bytes

      b = Chunkers::Batch.new
      assert_equal 20 * 1024 * 1024, b.max_body_bytes
      assert_equal 2000, b.max_events_per_batch
    end

    def test_config_picks_chunker_from_use_batch
      cfg = Config.new(api_key: "K")
      assert_instance_of Chunkers::HttpV2, cfg.chunker

      cfg2 = Config.new(api_key: "K", use_batch: true)
      assert_instance_of Chunkers::Batch, cfg2.chunker
    end

    def test_config_accepts_custom_chunker
      custom = Chunker.new(max_body_bytes: 1, max_events_per_batch: 1, max_event_bytes: 1)
      cfg = Config.new(api_key: "K", chunker: custom)
      assert_same custom, cfg.chunker
    end
  end
end
