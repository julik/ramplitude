# frozen_string_literal: true

module Ramplitude
  # User-facing client. Parity with Python's Ramplitude class.
  class Client
    attr_reader :config, :sink, :uploader

    def initialize(api_key:, config: nil, sink: nil, uploader: nil)
      @config         = config || Config.new
      @config.api_key = api_key
      yield @config if block_given?

      @sink     = sink     || @config.sink     || Sinks::InMemory.new
      @uploader = uploader || @config.uploader || Uploaders::Threaded.new

      @sink.setup(@config)
      @uploader.setup(@config, @sink)

      @timeline = Timeline.new
      @timeline.setup(self)

      add(Plugins::Context.new)
      add(Plugins::AmplitudeDestination.new)

      register_at_exit
    end

    # --- Tracking --------------------------------------------------------

    def track(event_or_type, **opts)
      event = case event_or_type
              when Event
                event_or_type
              when String, Symbol
                e = Event.new(event_type: event_or_type.to_s, **opts)
                yield(e) if block_given?
                e
              else
                raise ArgumentError, "track expects an Event or a String/Symbol event_type"
              end
      @timeline.process(event)
    end

    def identify(identify_or_user_id = nil, **opts, &block)
      identify_obj, options = normalize_identify(identify_or_user_id, opts, &block)
      unless identify_obj.valid?
        @config.logger&.warn("Empty identify properties — skipping")
        return
      end
      event = IdentifyEvent.new(user_properties: identify_obj.user_properties, **options)
      @timeline.process(event)
    end

    def group_identify(group_type, group_name, identify_obj = nil, **opts, &block)
      identify_obj ||= Identify.new
      yield(identify_obj) if block
      unless identify_obj.valid?
        @config.logger&.warn("Empty group identify properties — skipping")
        return
      end
      event = GroupIdentifyEvent.new(
        groups: { group_type => group_name },
        group_properties: identify_obj.user_properties,
        **opts,
      )
      @timeline.process(event)
    end

    def set_group(group_type, group_name, **opts)
      id = Identify.new.set(group_type, group_name)
      event = IdentifyEvent.new(
        groups: { group_type => group_name },
        user_properties: id.user_properties,
        **opts,
      )
      @timeline.process(event)
    end

    REVENUE_KWARGS = %i[price quantity product_id revenue_type receipt
                        receipt_signature revenue currency event_properties].freeze

    def revenue(revenue_or_args = nil, **opts)
      if revenue_or_args.is_a?(Revenue)
        rev = revenue_or_args
        event_opts = opts
      else
        rev_args, event_opts = opts.partition { |k, _| REVENUE_KWARGS.include?(k) }.map(&:to_h)
        rev = Revenue.new(**rev_args)
      end
      unless rev.valid?
        @config.logger&.warn("Invalid revenue (price must be numeric) — skipping")
        return
      end
      event = rev.to_revenue_event
      event_opts.each { |k, v| event.public_send("#{k}=", v) if event.respond_to?("#{k}=") }
      @timeline.process(event)
    end

    # --- Lifecycle -------------------------------------------------------

    def flush = @uploader.flush

    def shutdown
      return if @shutdown
      @shutdown = true
      @config.opt_out = true
      @timeline.shutdown
    end

    # --- Plugins ---------------------------------------------------------

    def add(plugin)
      @timeline.add(plugin)
      plugin.setup(self)
      self
    end

    def remove(plugin)
      @timeline.remove(plugin)
      self
    end

    def before(&block)      = add(Plugin::BlockPlugin.new(PluginType::BEFORE, &block))
    def enrich(&block)      = add(Plugin::BlockPlugin.new(PluginType::ENRICHMENT, &block))
    def destination(plugin) = add(plugin)

    private

    def normalize_identify(arg, opts)
      case arg
      when Identify
        [arg, opts]
      when nil
        id = Identify.new
        yield(id) if block_given?
        [id, opts]
      else
        # Treat as user_id shorthand: identify("u-1") { |i| ... }
        id = Identify.new
        yield(id) if block_given?
        [id, opts.merge(user_id: arg)]
      end
    end

    def register_at_exit = at_exit { shutdown }
  end
end
