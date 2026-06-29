# frozen_string_literal: true

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
