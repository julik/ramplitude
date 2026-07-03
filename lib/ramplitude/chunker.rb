# frozen_string_literal: true

require "json"

module Ramplitude
  # Splits a stream of events into ready-to-POST payloads that stay under
  # Amplitude's server-side upload limits.
  #
  # Two limits apply at once — event count per batch AND serialized JSON body
  # size — so packing is done as a two-way bin-pack: each event is serialized
  # once up-front, then greedily appended to the current batch while both the
  # event count and the projected body size stay under budget.
  #
  # See https://amplitude.com/docs/apis/analytics/http-v2#upload-limit and
  # https://amplitude.com/docs/apis/analytics/batch-event-upload for the
  # per-endpoint numbers used by the concrete subclasses.
  class Chunker
    attr_reader :max_body_bytes, :max_events_per_batch, :max_event_bytes

    def initialize(max_body_bytes:, max_events_per_batch:, max_event_bytes:)
      @max_body_bytes       = max_body_bytes
      @max_events_per_batch = max_events_per_batch
      @max_event_bytes      = max_event_bytes
    end

    # Yields [body_json_string, batch_events] for each packed chunk. Events
    # whose *own* serialized size exceeds `max_event_bytes` are yielded as
    # solo chunks so the caller's response processor can drop them via the
    # normal 413 path.
    def each_chunk(events, api_key:, options: nil)
      return enum_for(:each_chunk, events, api_key: api_key, options: options) unless block_given?

      prefix, suffix = envelope(api_key, options)
      envelope_overhead = prefix.bytesize + suffix.bytesize
      budget = @max_body_bytes - envelope_overhead

      batch = []
      batch_jsons = []
      batch_bytes = 0

      flush = lambda do
        next if batch.empty?
        yield build_body(prefix, suffix, batch_jsons), batch
        batch = []
        batch_jsons = []
        batch_bytes = 0
      end

      events.each do |event|
        event_json  = JSON.generate(event.to_h)
        event_bytes = event_json.bytesize

        if event_bytes > @max_event_bytes || event_bytes > budget
          flush.call
          yield build_body(prefix, suffix, [event_json]), [event]
          next
        end

        # +1 byte for the comma separator between events, when appending.
        added = batch.empty? ? event_bytes : event_bytes + 1

        if batch.size >= @max_events_per_batch || batch_bytes + added > budget
          flush.call
          added = event_bytes
        end

        batch << event
        batch_jsons << event_json
        batch_bytes += added
      end

      flush.call
    end

    private

    def envelope(api_key, options)
      head = { "api_key" => api_key }
      # Serialize the envelope with an empty events array, then split around
      # the empty array so we know exactly what surrounds the event list.
      head_json = JSON.generate(head.merge("events" => []))
      prefix, suffix = head_json.split('"events":[]', 2)
      prefix = "#{prefix}\"events\":["
      suffix = "]#{suffix}"
      if options
        # Insert options *before* the closing brace of the envelope.
        opts_json = JSON.generate(options)
        suffix = suffix.sub(/\}\z/, ",\"options\":#{opts_json}}")
      end
      [prefix, suffix]
    end

    def build_body(prefix, suffix, event_jsons)
      "#{prefix}#{event_jsons.join(",")}#{suffix}"
    end
  end
end
