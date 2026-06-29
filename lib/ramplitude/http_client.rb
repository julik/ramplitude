# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "stringio"
require "zlib"

module Ramplitude
  module HttpStatus
    SUCCESS            = 200
    INVALID_REQUEST    = 400
    TIMEOUT            = 408
    PAYLOAD_TOO_LARGE  = 413
    TOO_MANY_REQUESTS  = 429
    FAILED             = 500
    UNKNOWN            = -1

    def self.classify(code)
      return SUCCESS           if (200..299).cover?(code)
      return TOO_MANY_REQUESTS if code == 429
      return PAYLOAD_TOO_LARGE if code == 413
      return TIMEOUT           if code == 408
      return INVALID_REQUEST   if (400..499).cover?(code)
      return FAILED            if code >= 500
      UNKNOWN
    end
  end

  class Response
    attr_reader :status, :code, :body

    def initialize(status: HttpStatus::UNKNOWN, code: nil, body: nil)
      @status = status
      @code   = code || status
      @body   = body || {}
    end

    def self.parse(code, body_str)
      body = begin
        JSON.parse(body_str.to_s)
      rescue JSON::ParserError
        {}
      end
      code_from_body = body["code"] || code
      new(status: HttpStatus.classify(code_from_body), code: code_from_body, body: body)
    end

    def error                          = @body["error"] || ""
    def missing_field                  = @body["missing_field"]
    def events_with_invalid_fields     = @body["events_with_invalid_fields"]
    def events_with_missing_fields     = @body["events_with_missing_fields"]
    def events_with_invalid_id_lengths = @body["events_with_invalid_id_lengths"]
    def silenced_events                = @body["silenced_events"]
    def throttled_events               = @body["throttled_events"]

    def exceeds_daily_quota?(event)
      (@body["exceeded_daily_quota_users"] || []).include?(event.user_id) ||
        (@body["exceeded_daily_quota_devices"] || []).include?(event.device_id)
    end

    def invalid_or_silenced_indices
      out = Set.new
      [events_with_missing_fields, events_with_invalid_fields,
       events_with_invalid_id_lengths].each do |field_map|
        next unless field_map
        field_map.each_value { |arr| out.merge(arr) }
      end
      out.merge(silenced_events) if silenced_events
      out
    end
  end

  class HttpClient
    # Bodies smaller than this aren't worth compressing — the gzip header
    # overhead would dominate. 1 KiB is the conventional cutoff.
    GZIP_MIN_BYTES = 1024

    def self.post(url, payload, headers: nil, gzip: true)
      uri = URI(url)
      req = Net::HTTP::Post.new(uri.request_uri)
      req["Content-Type"]    = "application/json; charset=UTF-8"
      req["Accept"]          = "*/*"
      req["Accept-Encoding"] = "gzip"
      headers&.each { |k, v| req[k] = v }

      body, encoding = maybe_gzip(payload, gzip)
      req["Content-Encoding"] = encoding if encoding
      req.body = body

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = Constants::CONNECTION_TIMEOUT
      http.read_timeout = Constants::CONNECTION_TIMEOUT

      begin
        res = http.request(req)
        Response.parse(res.code.to_i, decode_body(res))
      rescue Net::OpenTimeout, Net::ReadTimeout
        Response.new(status: HttpStatus::TIMEOUT, code: 408, body: { "error" => "timeout" })
      rescue StandardError => e
        Response.new(status: HttpStatus::UNKNOWN, code: -1, body: { "error" => e.message })
      end
    end

    def self.maybe_gzip(payload, gzip)
      bytes = payload.bytesize
      return [payload, nil] unless gzip && bytes >= GZIP_MIN_BYTES

      buf = StringIO.new(+"".b)
      gz  = Zlib::GzipWriter.new(buf)
      gz.write(payload)
      gz.close
      [buf.string, "gzip"]
    end

    # Net::HTTP normally inflates gzipped responses for you, BUT only when it
    # sets the Accept-Encoding header itself. We set it explicitly, which
    # disables that auto-decode — so we decode the body ourselves.
    def self.decode_body(res)
      return res.body unless res["content-encoding"].to_s.downcase.include?("gzip")
      Zlib::GzipReader.new(StringIO.new(res.body)).read
    rescue Zlib::GzipFile::Error
      res.body
    end
  end
end

require "set"
