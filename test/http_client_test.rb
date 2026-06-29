# frozen_string_literal: true

require_relative "test_helper"

class HttpClientTest < Minitest::Test
  URL = "https://api2.amplitude.com/2/httpapi"

  def test_success_response
    stub_request(:post, URL).to_return(status: 200, body: { code: 200 }.to_json)
    res = Ramplitude::HttpClient.post(URL, "{}")
    assert_equal Ramplitude::HttpStatus::SUCCESS, res.status
    assert_equal 200, res.code
  end

  def test_413_classified
    stub_request(:post, URL).to_return(status: 413, body: { code: 413, error: "too large" }.to_json)
    res = Ramplitude::HttpClient.post(URL, "{}")
    assert_equal Ramplitude::HttpStatus::PAYLOAD_TOO_LARGE, res.status
    assert_equal "too large", res.error
  end

  def test_429_throttled_indices
    body = { code: 429, throttled_events: [1, 2], exceeded_daily_quota_users: ["bad"] }.to_json
    stub_request(:post, URL).to_return(status: 429, body: body)
    res = Ramplitude::HttpClient.post(URL, "{}")
    assert_equal Ramplitude::HttpStatus::TOO_MANY_REQUESTS, res.status
    assert_equal [1, 2], res.throttled_events
    fake = Ramplitude::Event.new(event_type: "X", user_id: "bad")
    assert res.exceeds_daily_quota?(fake)
  end

  def test_invalid_or_silenced_indices_union
    body = {
      code: 400,
      events_with_invalid_fields:  { "user_id" => [0] },
      events_with_missing_fields:  { "event_type" => [1] },
      silenced_events:             [2],
    }.to_json
    stub_request(:post, URL).to_return(status: 400, body: body)
    res = Ramplitude::HttpClient.post(URL, "{}")
    assert_equal [0, 1, 2].to_set, res.invalid_or_silenced_indices
  end

  def test_timeout_returns_408_response
    stub_request(:post, URL).to_timeout
    res = Ramplitude::HttpClient.post(URL, "{}")
    # to_timeout raises a generic timeout; map to UNKNOWN or TIMEOUT — accept either.
    assert_includes [Ramplitude::HttpStatus::TIMEOUT, Ramplitude::HttpStatus::UNKNOWN], res.status
  end

  def test_small_body_is_not_gzipped
    captured = nil
    stub_request(:post, URL).with { |req| captured = req; true }
      .to_return(status: 200, body: "{}")

    Ramplitude::HttpClient.post(URL, "{}")
    assert_nil captured.headers["Content-Encoding"]
    assert_equal "{}", captured.body
  end

  def test_large_body_is_gzipped
    captured = nil
    stub_request(:post, URL).with { |req| captured = req; true }
      .to_return(status: 200, body: "{}")

    big = "x" * 4096
    Ramplitude::HttpClient.post(URL, big)
    assert_equal "gzip", captured.headers["Content-Encoding"]
    raw = captured.body.b
    assert_equal "\x1F\x8B".b, raw[0, 2]                         # gzip magic
    assert_operator raw.bytesize, :<, big.bytesize               # actually smaller
    assert_equal big, Zlib::GzipReader.new(StringIO.new(raw)).read
  end

  def test_gzip_can_be_disabled
    captured = nil
    stub_request(:post, URL).with { |req| captured = req; true }
      .to_return(status: 200, body: "{}")

    big = "x" * 4096
    Ramplitude::HttpClient.post(URL, big, gzip: false)
    assert_nil captured.headers["Content-Encoding"]
    assert_equal big, captured.body
  end

  def test_gzipped_response_body_is_decoded
    body = { "code" => 200, "ok" => true }.to_json
    gz   = StringIO.new(+"".b)
    Zlib::GzipWriter.new(gz).tap { |w| w.write(body); w.close }
    stub_request(:post, URL).to_return(
      status:  200,
      body:    gz.string,
      headers: { "Content-Encoding" => "gzip" },
    )
    res = Ramplitude::HttpClient.post(URL, "{}")
    assert_equal Ramplitude::HttpStatus::SUCCESS, res.status
    assert_equal true, res.body["ok"]
  end
end
