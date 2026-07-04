# frozen_string_literal: true

require_relative "test_helper"

# End-to-end client tests using the Manual uploader (no background threads)
# and WebMock for HTTP.
class ClientTest < Minitest::Test
  URL = "https://api2.amplitude.com/2/httpapi"

  def build_client
    Ramplitude::Client.new(
      api_key:  "test-key",
      uploader: Ramplitude::Uploaders::Manual.new,
    )
  end

  def test_track_then_manual_flush_posts_to_amplitude
    received = nil
    stub_request(:post, URL).with do |req|
      received = JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    client = build_client
    client.track("Page Viewed", user_id: "u-1", event_properties: { path: "/" })
    client.flush.wait

    assert_equal "test-key", received["api_key"]
    assert_equal 1, received["events"].size
    ev = received["events"].first
    assert_equal "Page Viewed", ev["event_type"]
    assert_equal "u-1", ev["user_id"]
    assert ev["time"]
    assert ev["insert_id"]
    assert_equal Ramplitude::Constants::SDK_VERSION_STRING, ev["library"]
  end

  def test_track_block_form_sets_attrs
    received = nil
    stub_request(:post, URL).with do |req|
      received = JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    client = build_client
    client.track("Click") do |e|
      e.user_id  = "u-2"
      e.platform = "web"
    end
    client.flush.wait

    ev = received["events"].first
    assert_equal "u-2", ev["user_id"]
    assert_equal "web", ev["platform"]
  end

  def test_identify_emits_identify_event_with_user_properties
    received = nil
    stub_request(:post, URL).with do |req|
      received = JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    client = build_client
    client.identify(user_id: "u-1") { |i| i.set(:plan, "pro").add(:logins, 1) }
    client.flush.wait

    ev = received["events"].first
    assert_equal "$identify", ev["event_type"]
    assert_equal({ "plan" => "pro" }, ev["user_properties"]["$set"])
    assert_equal({ "logins" => 1 }, ev["user_properties"]["$add"])
  end

  def test_revenue_event_carries_revenue_properties
    received = nil
    stub_request(:post, URL).with do |req|
      received = JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    client = build_client
    client.revenue(user_id: "u-1", price: 9.99, quantity: 2, product_id: "sku-42")
    client.flush.wait

    ev = received["events"].first
    assert_equal "revenue_amount", ev["event_type"]
    props = ev["event_properties"]
    assert_equal 9.99, props["$price"]
    assert_equal 2,    props["$quantity"]
    assert_equal "sku-42", props["$productId"]
  end

  def test_set_group_adds_group_and_user_property
    received = nil
    stub_request(:post, URL).with do |req|
      received = JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    client = build_client
    client.set_group("org_id", "15", user_id: "u-1")
    client.flush.wait

    ev = received["events"].first
    assert_equal "$identify", ev["event_type"]
    assert_equal({ "org_id" => "15" }, ev["groups"])
    assert_equal({ "org_id" => "15" }, ev["user_properties"]["$set"])
  end

  def test_opt_out_skips_pipeline
    stub = stub_request(:post, URL).to_return(status: 200, body: "{}")
    client = build_client
    client.config.opt_out = true
    client.track("Ignored", user_id: "u-1")
    client.flush.wait
    assert_not_requested stub
  end

  def test_before_block_plugin_mutates_event
    received = nil
    stub_request(:post, URL).with do |req|
      received = JSON.parse(req.body)
      true
    end.to_return(status: 200, body: { code: 200 }.to_json)

    client = build_client
    client.before { |e| e.platform ||= "web"; e }
    client.track("Click", user_id: "u-1")
    client.flush.wait

    assert_equal "web", received["events"].first["platform"]
  end

  def test_event_without_user_or_device_id_raises
    stub = stub_request(:post, URL).to_return(status: 200, body: "{}")
    client = build_client
    err = assert_raises(Ramplitude::InvalidEventError) { client.track("No IDs") }
    assert_match(/user_id/, err.message)
    assert_match(/device_id/, err.message)
    client.flush.wait
    assert_not_requested stub
  end

  def test_enrich_can_supply_identity_before_the_check
    stub_request(:post, URL).to_return(status: 200, body: "{}")
    client = build_client
    client.enrich { |e| e.user_id ||= "from-enricher"; e }
    client.track("No IDs at call site")   # must not raise
    client.flush.wait
  end

  def test_use_batch_routes_to_batch_endpoint
    stub_request(:post, "https://api2.amplitude.com/batch")
      .to_return(status: 200, body: { code: 200 }.to_json)

    cfg = Ramplitude::Config.new(use_batch: true)
    client = Ramplitude::Client.new(
      api_key:  "test-key",
      config:   cfg,
      uploader: Ramplitude::Uploaders::Manual.new,
    )
    client.track("Batched", user_id: "u-1")
    client.flush.wait

    assert_requested :post, "https://api2.amplitude.com/batch"
  end

  # Simulates a mid-flush crash (e.g. Timeout::Error slipping past HttpClient's
  # rescues, or a bug in the response processor). The batch was already pulled
  # from the sink — the ensure block must push it back so the next drain sees
  # it, otherwise events are silently lost.
  def test_send_one_requeues_batch_when_unexpected_error_is_raised
    sink = Ramplitude::Sinks::InMemory.new
    cfg  = Ramplitude::Config.new(api_key: "test-key")
    sink.setup(cfg)
    uploader = Ramplitude::Uploaders::Manual.new
    uploader.setup(cfg, sink)

    event = Ramplitude::Event.new(event_type: "X", user_id: "u-1")
    boom  = Class.new(StandardError)

    Ramplitude::HttpClient.stub(:post, ->(_url, _body) { raise boom, "kaboom" }) do
      assert_raises(boom) { uploader.send_one("body", [event]) }
    end

    # Event must have been pushed back into the sink.
    assert_equal 1, sink.size
    pulled = sink.pull_all
    assert_equal "u-1", pulled.first.user_id
  end
end
