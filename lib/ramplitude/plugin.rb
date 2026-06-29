# frozen_string_literal: true

module Ramplitude
  module Plugin
    # Base plugin. Subclasses override #execute.
    class Base
      attr_reader :plugin_type

      def initialize(plugin_type)
        @plugin_type = plugin_type
      end

      def setup(_client) = nil
      def execute(event) = event
    end

    # Enrichment / before plugins that may also dispatch on event subclass.
    class EventPlugin < Base
      def execute(event)
        case event
        when GroupIdentifyEvent then group_identify(event)
        when IdentifyEvent      then identify(event)
        when RevenueEvent       then revenue(event)
        else                         track(event)
        end
      end

      def track(event)          = event
      def identify(event)       = event
      def group_identify(event) = event
      def revenue(event)        = event
    end

    # Block-sugar wrappers used by Client#before / #enrich.
    class BlockPlugin < Base
      def initialize(plugin_type, &block)
        super(plugin_type)
        @block = block
      end

      def execute(event) = @block.call(event)
    end

    # Sends events to a destination. Has its own nested Timeline so users can
    # add per-destination middleware.
    class Destination < EventPlugin
      attr_reader :timeline

      def initialize
        super(PluginType::DESTINATION)
        @timeline = Timeline.new
      end

      def setup(client) = @timeline.setup(client)

      def add(plugin)
        @timeline.add(plugin)
        self
      end

      def remove(plugin)
        @timeline.remove(plugin)
        self
      end

      def execute(event)
        event = @timeline.process(event)
        super
      end

      def flush = nil
      def shutdown = nil
    end
  end
end
