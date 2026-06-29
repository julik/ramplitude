# frozen_string_literal: true

module Ramplitude
  # Abstract sink — anything that can buffer events between the pipeline and
  # the uploader. Subclasses must implement push/pull/pull_all.
  class Sink
    # @return [Array(Boolean, String|nil)] accepted, optional reason
    def push(_event, delay_ms: 0) = raise(NotImplementedError)

    # @return [Array<Event>] up to `max` events that are due now
    def pull(max:) = raise(NotImplementedError)

    # @return [Array<Event>] all buffered events regardless of delay
    def pull_all = raise(NotImplementedError)

    # @return [Integer, nil] number of buffered events, or nil if unknown
    def size = nil

    # Block until events are likely available, up to timeout_ms. Optional.
    def wait(timeout_ms:) = nil

    # Lifecycle hooks (optional). The default sink uses these to know the
    # max_retries / capacity it should enforce.
    attr_accessor :config

    def setup(config, _uploader = nil) = (@config = config)

    def max_retries = (@config ? @config.flush_max_retries : Constants::FLUSH_MAX_RETRIES)
  end
end
