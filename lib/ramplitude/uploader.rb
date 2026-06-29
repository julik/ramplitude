# frozen_string_literal: true

require "json"

module Ramplitude
  # Abstract uploader. Subclasses move events from a Sink to the Ramplitude HTTP
  # API. Lifecycle: setup -> start (optional) -> flush (any number) -> stop.
  class Uploader
    attr_accessor :config, :sink

    def setup(config, sink)
      @config = config
      @sink   = sink
      @processor = ResponseProcessor.new(config: config, sink: sink)
    end

    def start = nil

    # @return [Object] something responding to #wait (returns nil)
    def flush
      events = @sink.pull_all
      return NoopFuture.new if events.nil? || events.empty?
      send_batches(events)
      NoopFuture.new
    end

    def stop = flush

    # Helper: split into batches and send them sequentially. Override for
    # concurrency.
    def send_batches(events)
      batch_size = @config.flush_queue_size
      events.each_slice(batch_size) { |batch| send_one(batch) }
    end

    def send_one(batch)
      payload = build_payload(batch)
      res = HttpClient.post(@config.server_url, payload)
      @processor.process(res, batch)
    rescue InvalidAPIKeyError
      @config.logger&.error("Invalid Ramplitude API key")
    end

    def build_payload(events)
      body = { "api_key" => @config.api_key, "events" => events.map(&:to_h) }
      body["options"] = @config.options if @config.options
      JSON.generate(body)
    end
  end

  # Minimal future-ish object so callers can do `client.flush.wait`.
  class NoopFuture
    def wait  = nil
    def value = nil
  end
end
