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

    # Helper: chunk events into limit-safe payloads and send them sequentially.
    # Override for concurrency.
    def send_batches(events)
      each_chunk(events) { |body, batch| send_one(body, batch) }
    end

    def send_one(body, batch)
      completed = false
      res = HttpClient.post(@config.server_url, body)
      @processor.process(res, batch)
      completed = true
    rescue InvalidAPIKeyError
      # Bad key won't get better on retry — drop the batch on purpose.
      completed = true
      @config.logger&.error("Invalid Ramplitude API key")
    ensure
      requeue_on_crash(batch) unless completed
    end

    # If we pulled events from the sink and then something unexpected blew up
    # before ResponseProcessor could take ownership of them (bug, Timeout::Error
    # escaping HttpClient, thread interrupt, …) push them back so the next
    # drain picks them up. Best-effort — a broken sink can still lose data.
    def requeue_on_crash(batch)
      batch.each do |event|
        begin
          @sink.push(event, delay_ms: 0)
        rescue StandardError => e
          @config.logger&.error("Sink push failed while requeueing after crash: #{e.class}: #{e.message}")
        end
      end
    end

    def each_chunk(events, &block)
      @config.chunker.each_chunk(
        events,
        api_key: @config.api_key,
        options: @config.options,
        &block
      )
    end
  end

  # Minimal future-ish object so callers can do `client.flush.wait`.
  class NoopFuture
    def wait  = nil
    def value = nil
  end
end
