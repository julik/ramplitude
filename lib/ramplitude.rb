# frozen_string_literal: true

module Ramplitude
end

require "ramplitude/version"
require "ramplitude/constants"
require "ramplitude/errors"
require "ramplitude/utils"
require "ramplitude/plan"
require "ramplitude/event"
require "ramplitude/identify"
require "ramplitude/revenue"
require "ramplitude/chunker"
require "ramplitude/chunkers/http_v2"
require "ramplitude/chunkers/batch"
require "ramplitude/config"
require "ramplitude/http_client"
require "ramplitude/response_processor"
require "ramplitude/sink"
require "ramplitude/sinks/in_memory"
require "ramplitude/sinks/file"
require "ramplitude/uploader"
require "ramplitude/uploaders/threaded"
require "ramplitude/uploaders/manual"
require "ramplitude/uploaders/null"
require "ramplitude/timeline"
require "ramplitude/plugin"
require "ramplitude/plugins/context"
require "ramplitude/plugins/amplitude_destination"
require "ramplitude/bulk_flusher"
require "ramplitude/client"

# Redis sink is optional — loaded only when the `redis` gem is present.
begin
  require "redis"
  require "ramplitude/sinks/redis"
rescue LoadError
  # Redis gem not installed — Sinks::Redis won't be available.
end

module Ramplitude
  class << self
    attr_accessor :default_client

    # Configure a process-wide singleton client. Handy for Rails initializers.
    #
    #   Ramplitude.configure { |c| c.api_key = "..."; c.server_zone = :eu }
    def configure
      cfg = Config.new
      yield cfg
      @default_client = Client.new(api_key: cfg.api_key, config: cfg)
    end

    def track(*args, **opts, &block)
      ensure_client!
      @default_client.track(*args, **opts, &block)
    end

    def identify(*args, **opts, &block)       = (ensure_client!; @default_client.identify(*args, **opts, &block))
    def group_identify(*args, **opts, &block) = (ensure_client!; @default_client.group_identify(*args, **opts, &block))
    def set_group(*args, **opts)              = (ensure_client!; @default_client.set_group(*args, **opts))
    def revenue(*args, **opts)                = (ensure_client!; @default_client.revenue(*args, **opts))
    def flush                                 = (ensure_client!; @default_client.flush)
    def shutdown                              = @default_client&.shutdown

    private

    def ensure_client!
      raise ConfigurationError, "Call Ramplitude.configure { |c| c.api_key = ... } first" unless @default_client
    end
  end
end
