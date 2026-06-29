# frozen_string_literal: true

require "securerandom"

module Ramplitude
  module Plugins
    # Default BEFORE plugin. Stamps time, insert_id, library, plan,
    # ingestion_metadata if not already set.
    class Context < Plugin::Base
      def initialize
        super(PluginType::BEFORE)
        @library = Constants::SDK_VERSION_STRING
      end

      def setup(client) = (@config = client.config)

      def execute(event)
        event.time      ||= Utils.current_milliseconds
        event.insert_id ||= SecureRandom.uuid
        event.library   ||= @library
        event.plan      ||= @config.plan if @config&.plan
        event.ingestion_metadata ||= @config.ingestion_metadata if @config&.ingestion_metadata
        event
      end
    end
  end
end
