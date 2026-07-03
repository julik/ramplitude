# frozen_string_literal: true

require "json"

module Ramplitude
  # Three-stage plugin pipeline. Each stage is locked separately.
  # Destination plugins always receive a deep copy of the event.
  class Timeline
    attr_accessor :config

    def initialize
      @plugins = { PluginType::BEFORE => [], PluginType::ENRICHMENT => [], PluginType::DESTINATION => [] }
      @locks   = { PluginType::BEFORE => Mutex.new, PluginType::ENRICHMENT => Mutex.new, PluginType::DESTINATION => Mutex.new }
    end

    def setup(client)
      @config = client.config
    end

    def add(plugin)
      @locks.fetch(plugin.plugin_type).synchronize { @plugins[plugin.plugin_type] << plugin }
    end

    def remove(plugin)
      @plugins.each_key do |t|
        @locks[t].synchronize { @plugins[t] = @plugins[t].reject { |p| p.equal?(plugin) } }
      end
    end

    def process(event)
      return event if @config&.opt_out
      e = apply(PluginType::BEFORE, event)
      e = apply(PluginType::ENRICHMENT, e)
      require_identity!(e) if e
      apply(PluginType::DESTINATION, e)
      e
    end

    def flush
      @plugins[PluginType::DESTINATION].map do |d|
        begin
          d.flush if d.respond_to?(:flush)
        rescue StandardError => err
          @config&.logger&.error("Destination flush error: #{err.message}")
          nil
        end
      end
    end

    def shutdown
      @plugins[PluginType::DESTINATION].each do |d|
        d.shutdown if d.respond_to?(:shutdown)
      end
    end

    private

    # Amplitude ingestion rejects any event lacking both user_id and device_id.
    # Enforce it locally so callers get a stack trace at the track site instead
    # of a silent server-side rejection surfacing much later via `on_event`.
    def require_identity!(event)
      return if present?(event.user_id) || present?(event.device_id)
      raise InvalidEventError, <<~MSG
        Event rejected — neither user_id nor device_id is set after
        enrichment, but Amplitude requires at least one of them on every event.

        Event #{event.event_type.inspect} as it would have been sent:
        #{JSON.pretty_generate(event.to_h)}

        To remediate:
          * Pass user_id: / device_id: when calling track.
          * Or register an ENRICHMENT plugin that fills one in from your
            request context (e.g. ActiveSupport::CurrentAttributes).
      MSG
    end

    def present?(v) = !v.nil? && !(v.respond_to?(:empty?) && v.empty?)

    def apply(type, event)
      result = event
      @locks[type].synchronize do
        @plugins[type].each do |plugin|
          break unless result
          begin
            if type == PluginType::DESTINATION
              plugin.execute(deep_dup(result))
            else
              result = plugin.execute(result)
            end
          rescue InvalidEventError => e
            @config&.logger&.warn("Invalid event: #{e.message}")
          rescue StandardError => e
            @config&.logger&.error("Plugin #{plugin.class} crashed: #{e.message}")
          end
        end
      end
      result
    end

    def deep_dup(event)
      Marshal.load(Marshal.dump(event))
    end
  end
end
