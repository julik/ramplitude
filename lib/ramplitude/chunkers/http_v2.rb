# frozen_string_literal: true

module Ramplitude
  module Chunkers
    # Limits for the /2/httpapi endpoint:
    #   * 1 MB max request body
    #   * 32 KB max per event
    # See https://amplitude.com/docs/apis/analytics/http-v2#upload-limit.
    #
    # No explicit event-count cap is documented — we still expose one so the
    # base chunker's second bin-pack dimension has a sane ceiling.
    class HttpV2 < Chunker
      MAX_BODY_BYTES       = 1 * 1024 * 1024
      MAX_EVENT_BYTES      = 32 * 1024
      MAX_EVENTS_PER_BATCH = 1000

      def initialize(max_body_bytes: MAX_BODY_BYTES,
                     max_events_per_batch: MAX_EVENTS_PER_BATCH,
                     max_event_bytes: MAX_EVENT_BYTES)
        super
      end
    end
  end
end
