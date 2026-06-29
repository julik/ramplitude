# frozen_string_literal: true

require_relative "test_helper"

class ResponseProcessorTest < Minitest::Test
  def setup
    @cfg = Ramplitude::Config.new(api_key: "x", flush_queue_size: 200, flush_max_retries: 3)
    @sink = Ramplitude::Sinks::InMemory.new
    @sink.setup(@cfg)
    @processor = Ramplitude::ResponseProcessor.new(config: @cfg, sink: @sink)
  end

  def make_event(user_id: "u")
    Ramplitude::Event.new(event_type: "X", user_id: user_id)
  end

  def test_success_invokes_callbacks
    seen = []
    @cfg.on_event = ->(e, code, msg) { seen << [e.user_id, code, msg] }
    res = Ramplitude::Response.new(status: Ramplitude::HttpStatus::SUCCESS, code: 200, body: {})
    @processor.process(res, [make_event(user_id: "u1")])
    assert_equal [["u1", 200, "Event sent successfully."]], seen
  end

  def test_413_with_batch_shrinks_divider_and_requeues
    res = Ramplitude::Response.new(status: Ramplitude::HttpStatus::PAYLOAD_TOO_LARGE, code: 413, body: { "error" => "too big" })
    events = [make_event(user_id: "a"), make_event(user_id: "b")]
    @processor.process(res, events)
    assert_equal 100, @cfg.flush_queue_size # 200/2
    assert_equal 2, @sink.size
  end

  def test_413_single_event_calls_back
    seen = []
    @cfg.on_event = ->(_, code, msg) { seen << [code, msg] }
    res = Ramplitude::Response.new(status: Ramplitude::HttpStatus::PAYLOAD_TOO_LARGE, code: 413, body: { "error" => "huge" })
    @processor.process(res, [make_event])
    assert_equal [[413, "huge"]], seen
  end

  def test_invalid_api_key_raises
    res = Ramplitude::Response.new(status: Ramplitude::HttpStatus::INVALID_REQUEST, code: 400, body: { "error" => "Invalid API key: bad" })
    assert_raises(Ramplitude::InvalidAPIKeyError) do
      @processor.process(res, [make_event])
    end
  end

  def test_400_invalid_indices_split_dead_from_retry
    seen = []
    @cfg.on_event = ->(e, _c, _m) { seen << e.user_id }
    res = Ramplitude::Response.new(
      status: Ramplitude::HttpStatus::INVALID_REQUEST,
      code:   400,
      body:   { "error" => "bad", "events_with_invalid_fields" => { "x" => [0] } },
    )
    events = [make_event(user_id: "dead"), make_event(user_id: "retry")]
    @processor.process(res, events)
    assert_equal ["dead"], seen
    assert_equal 1, @sink.size # "retry" got requeued
  end

  def test_429_throttled_quota_dead_vs_delayed
    seen = []
    @cfg.on_event = ->(e, _c, _m) { seen << e.user_id }
    res = Ramplitude::Response.new(
      status: Ramplitude::HttpStatus::TOO_MANY_REQUESTS,
      code:   429,
      body:   { "throttled_events" => [0, 1], "exceeded_daily_quota_users" => ["dead"] },
    )
    events = [make_event(user_id: "dead"), make_event(user_id: "delayed"), make_event(user_id: "ok")]
    @processor.process(res, events)
    assert_equal ["dead"], seen
    assert_equal 2, @sink.size # delayed + ok requeued
  end

  def test_5xx_requeues
    res = Ramplitude::Response.new(status: Ramplitude::HttpStatus::FAILED, code: 500, body: {})
    @processor.process(res, [make_event, make_event])
    assert_equal 2, @sink.size
  end
end
