# frozen_string_literal: true

require "logger"

module Ramplitude
  class Config
    attr_accessor :api_key,
                  :flush_interval_ms,
                  :flush_max_retries,
                  :logger,
                  :min_id_length,
                  :on_event,                # ->(event, code, message)
                  :server_zone,
                  :use_batch,
                  :opt_out,
                  :plan,
                  :ingestion_metadata,
                  :sink,                    # Ramplitude::Sink instance (optional)
                  :uploader                 # Ramplitude::Uploader instance (optional)

    def initialize(api_key: nil,
                   flush_queue_size:  Constants::FLUSH_QUEUE_SIZE,
                   flush_interval_ms: Constants::FLUSH_INTERVAL_MS,
                   flush_max_retries: Constants::FLUSH_MAX_RETRIES,
                   logger:            Logger.new($stdout, progname: Constants::LOGGER_NAME),
                   min_id_length:     nil,
                   on_event:          nil,
                   server_zone:       Constants::DEFAULT_ZONE,
                   use_batch:         false,
                   server_url:        nil,
                   sink:              nil,
                   uploader:          nil,
                   plan:              nil,
                   ingestion_metadata: nil)
      @api_key            = api_key
      @flush_queue_size   = flush_queue_size
      @flush_size_divider = 1
      @flush_interval_ms  = flush_interval_ms
      @flush_max_retries  = flush_max_retries
      @logger             = logger
      @min_id_length      = min_id_length
      @on_event           = on_event
      @server_zone        = server_zone
      @use_batch          = use_batch
      @url                = server_url
      @sink               = sink
      @uploader           = uploader
      @opt_out            = false
      @plan               = plan
      @ingestion_metadata = ingestion_metadata
    end

    def flush_queue_size = [1, @flush_queue_size / @flush_size_divider].max

    def flush_queue_size=(size)
      @flush_queue_size = size
      @flush_size_divider = 1
    end

    def server_url
      return @url if @url
      Constants::SERVER_URL[@server_zone][@use_batch ? :batch : :v2]
    end

    def server_url=(url)
      @url = url
    end

    def options
      return nil unless min_id_length_valid? && @min_id_length
      { "min_id_length" => @min_id_length }
    end

    def valid?
      return false unless @api_key && !@api_key.empty?
      return false unless flush_queue_size > 0
      return false unless @flush_interval_ms > 0
      min_id_length_valid?
    end

    def min_id_length_valid? = @min_id_length.nil? || (@min_id_length.is_a?(Integer) && @min_id_length > 0)

    # Internal — bumped by ResponseProcessor on HTTP 413.
    def _increase_flush_divider = (@flush_size_divider += 1)
    def _reset_flush_divider    = (@flush_size_divider = 1)
  end
end
