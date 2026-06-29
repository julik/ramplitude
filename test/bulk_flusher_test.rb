# frozen_string_literal: true

require_relative "test_helper"

class BulkFlusherTest < Minitest::Test
  URL = "https://api2.amplitude.com/2/httpapi"

  def test_drains_sink_in_batches
    sink = Ramplitude::Sinks::InMemory.new
    cfg  = Ramplitude::Config.new(api_key: "k", flush_queue_size: 2)
    sink.setup(cfg)
    5.times { |i| sink.push(Ramplitude::Event.new(event_type: "X", user_id: "u#{i}")) }

    posts = []
    stub_request(:post, URL).with do |req|
      posts << JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    flusher = Ramplitude::BulkFlusher.new(api_key: "k", sink: sink, config: cfg)
    sent = flusher.drain

    assert_equal 5, sent
    assert_equal 3, posts.size # 2 + 2 + 1
    assert_equal [2, 2, 1], posts.map { |p| p["events"].size }
  end

  def test_5xx_requeues_for_next_drain
    sink = Ramplitude::Sinks::InMemory.new
    cfg  = Ramplitude::Config.new(api_key: "k", flush_queue_size: 10, flush_max_retries: 5)
    sink.setup(cfg)
    sink.push(Ramplitude::Event.new(event_type: "X", user_id: "u"))

    stub_request(:post, URL).to_return(status: 500, body: { code: 500 }.to_json)
    Ramplitude::BulkFlusher.new(api_key: "k", sink: sink, config: cfg).drain

    # Event got requeued with delay; pull_all sees it regardless of delay.
    assert_equal 1, sink.size
  end
end
