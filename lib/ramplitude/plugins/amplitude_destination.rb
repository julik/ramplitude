# frozen_string_literal: true

module Ramplitude
  module Plugins
    # The default destination — pushes events to the sink and lets the
    # uploader drain it.
    class AmplitudeDestination < Plugin::Destination
      def setup(client)
        super
        @config   = client.config
        @sink     = client.sink
        @uploader = client.uploader
      end

      def execute(event)
        event = @timeline.process(event)
        return unless verify_event(event)
        accepted, msg = @sink.push(event)
        if !accepted
          @config.logger&.warn("Sink rejected event: #{msg}")
        else
          @uploader.start
        end
      end

      def flush = @uploader.flush

      def shutdown
        @timeline.shutdown
        @uploader.stop
      end

      private

      def verify_event(event)
        return false unless event.is_a?(Event)
        return true  if event.is_a?(GroupIdentifyEvent)
        return false if event.event_type.nil? || event.event_type.empty?
        return false if event.user_id.nil? && event.device_id.nil?
        true
      end
    end
  end
end
