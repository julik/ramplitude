# frozen_string_literal: true

module Ramplitude
  module Chunkers
    # Limits for the /batch endpoint:
    #   * 20 MB max request body
    #   * 2000 events max per batch
    #   * 32 KB max per event
    # See https://amplitude.com/docs/apis/analytics/batch-event-upload.
    class Batch < Chunker
      MAX_BODY_BYTES       = 20 * 1024 * 1024
      MAX_EVENT_BYTES      = 32 * 1024
      MAX_EVENTS_PER_BATCH = 2000

      def initialize(max_body_bytes: MAX_BODY_BYTES,
                     max_events_per_batch: MAX_EVENTS_PER_BATCH,
                     max_event_bytes: MAX_EVENT_BYTES)
        super
      end
    end
  end
end
