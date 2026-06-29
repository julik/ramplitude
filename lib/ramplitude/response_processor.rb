# frozen_string_literal: true

module Ramplitude
  # Maps each HTTP outcome into the right combination of: invoke callbacks,
  # push events back to the sink with a delay, raise on bad API key, or
  # ask the config to shrink batch size (HTTP 413).
  #
  # Pure logic — usable both from the in-process uploader and the
  # out-of-process BulkFlusher.
  class ResponseProcessor
    def initialize(config:, sink:)
      @config = config
      @sink   = sink
    end

    def process(response, events)
      case response.status
      when HttpStatus::SUCCESS
        callback(events, response.code, "Event sent successfully.")
      when HttpStatus::TIMEOUT, HttpStatus::FAILED, HttpStatus::UNKNOWN
        requeue(events, 0, response)
      when HttpStatus::PAYLOAD_TOO_LARGE
        if events.size == 1
          callback(events, response.code, response.error)
        else
          @config._increase_flush_divider if events.size <= @config.flush_queue_size
          requeue(events, 0, response)
        end
      when HttpStatus::INVALID_REQUEST
        raise InvalidAPIKeyError, response.error if response.error.start_with?("Invalid API key:")
        if response.missing_field
          callback(events, response.code, "Request missing required field #{response.missing_field}")
        else
          bad = response.invalid_or_silenced_indices
          retry_events, dead = [], []
          events.each_with_index { |e, i| (bad.include?(i) ? dead : retry_events) << e }
          callback(dead, response.code, response.error)
          requeue(retry_events, 0, response)
        end
      when HttpStatus::TOO_MANY_REQUESTS
        throttled = response.throttled_events || []
        dead, delayed, retry_events = [], [], []
        events.each_with_index do |e, i|
          if throttled.include?(i)
            response.exceeds_daily_quota?(e) ? dead << e : delayed << e
          else
            retry_events << e
          end
        end
        callback(dead, response.code, "Exceeded daily quota")
        requeue(delayed, 30_000, response)
        requeue(retry_events, 0, response)
      else
        callback(events, response.code, response.error.empty? ? "Unknown error" : response.error)
      end
    end

    private

    def requeue(events, delay_ms, response)
      events.each do |event|
        event.retry_count += 1
        accepted, msg = @sink.push(event, delay_ms: delay_ms)
        callback([event], response.code, msg) unless accepted
      end
    end

    def callback(events, code, message)
      events.each do |event|
        begin
          @config.on_event&.call(event, code, message)
          event.trigger_callback(code, message)
        rescue StandardError => e
          @config.logger&.error("on_event callback raised: #{e.message}")
        end
      end
    end
  end
end
