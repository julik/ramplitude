# frozen_string_literal: true

module Ramplitude
  # Out-of-process drainer. Use it from a Sidekiq/ActiveJob to POST whatever
  # is sitting in a (typically Redis) sink. Reuses ResponseProcessor so
  # retries / 413 shrink / 429 throttling all behave the same as in-process.
  #
  # Example:
  #
  #   Ramplitude::BulkFlusher.new(
  #     api_key: ENV["AMPLITUDE_API_KEY"],
  #     sink:    Ramplitude::Sinks::Redis.new(redis: $redis, key: "amp:events"),
  #     config:  Ramplitude::Config.new(use_batch: true, flush_queue_size: 1000),
  #   ).drain(max_batches: 50)
  class BulkFlusher
    def initialize(api_key:, sink:, config: nil)
      @config = config || Config.new
      @config.api_key = api_key
      @sink = sink
      @sink.setup(@config)
      @processor = ResponseProcessor.new(config: @config, sink: @sink)
    end

    # Drain up to `max_batches` batches and return the number of events sent.
    # Stops early when the sink reports empty.
    def drain(max_batches: Float::INFINITY)
      sent = 0
      batches = 0
      while batches < max_batches
        batch = @sink.pull(max: @config.flush_queue_size)
        break if batch.empty?
        send_batch(batch)
        sent += batch.size
        batches += 1
      end
      sent
    end

    # Drain everything regardless of delay (used by shutdown jobs).
    def drain_all
      events = @sink.pull_all
      events.each_slice(@config.flush_queue_size) { |b| send_batch(b) }
      events.size
    end

    private

    def send_batch(batch)
      payload = JSON.generate(
        "api_key" => @config.api_key,
        "events"  => batch.map(&:to_h),
        **(@config.options ? { "options" => @config.options } : {})
      )
      res = HttpClient.post(@config.server_url, payload)
      @processor.process(res, batch)
    rescue InvalidAPIKeyError
      @config.logger&.error("Invalid Ramplitude API key — dropping batch of #{batch.size}")
    end
  end
end
