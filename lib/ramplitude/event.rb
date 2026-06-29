# frozen_string_literal: true

module Ramplitude
  # Mirrors Python's BaseEvent/EventOptions: a flat bag of optional fields.
  # Keys match the Python attribute names; #to_h emits the Ramplitude wire format
  # using EVENT_KEY_MAPPING.
  class Event
    # Ruby attr -> wire key. Order is the original Python EVENT_KEY_MAPPING.
    EVENT_KEY_MAPPING = {
      event_type:           "event_type",
      user_id:              "user_id",
      device_id:            "device_id",
      time:                 "time",
      event_properties:     "event_properties",
      user_properties:      "user_properties",
      groups:               "groups",
      app_version:          "app_version",
      platform:             "platform",
      os_name:              "os_name",
      os_version:           "os_version",
      device_brand:         "device_brand",
      device_manufacturer:  "device_manufacturer",
      device_model:         "device_model",
      carrier:              "carrier",
      country:              "country",
      region:               "region",
      city:                 "city",
      dma:                  "dma",
      language:             "language",
      price:                "price",
      quantity:             "quantity",
      revenue:              "revenue",
      product_id:           "productId",
      revenue_type:         "revenueType",
      currency:             "currency",
      location_lat:         "location_lat",
      location_lng:         "location_lng",
      ip:                   "ip",
      idfa:                 "idfa",
      idfv:                 "idfv",
      adid:                 "adid",
      android_id:           "android_id",
      event_id:             "event_id",
      session_id:           "session_id",
      insert_id:            "insert_id",
      library:              "library",
      plan:                 "plan",
      ingestion_metadata:   "ingestion_metadata",
      partner_id:           "partner_id",
      version_name:         "version_name",
      user_agent:           "user_agent",
      group_properties:     "group_properties",
    }.freeze

    EVENT_KEY_MAPPING.each_key { |k| attr_accessor(k) }

    # Per-event callback: ->(event, code, message)
    attr_accessor :on_event
    attr_accessor :retry_count

    def initialize(**attrs)
      @retry_count = 0
      attrs.each { |k, v| public_send("#{k}=", v) if respond_to?("#{k}=") }
    end

    def [](key) = (public_send(key) if respond_to?(key))

    def []=(key, val)
      public_send("#{key}=", val) if respond_to?("#{key}=")
    end

    def to_h
      out = {}
      EVENT_KEY_MAPPING.each do |attr, wire_key|
        val = public_send(attr)
        next if val.nil?
        out[wire_key] = case val
                       when Plan, IngestionMetadata then val.to_h
                       else val
                       end
      end
      Utils.truncate(out)
    end

    def to_json(*args) = to_h.to_json(*args)

    def trigger_callback(code, message = nil)
      return unless @on_event
      @on_event.call(self, code, message)
    rescue StandardError
      # Swallow callback errors — never let user code break the pipeline.
    end

    # Load options from another Event (parity with Python load_event_options).
    def load_event_options(other)
      return unless other
      EVENT_KEY_MAPPING.each_key do |attr|
        v = other.public_send(attr)
        public_send("#{attr}=", v) unless v.nil? || !public_send(attr).nil?
      end
      @on_event ||= other.on_event if other.respond_to?(:on_event)
      self
    end
  end

  class IdentifyEvent < Event
    def initialize(**attrs)
      super(**attrs)
      self.event_type = Constants::IDENTIFY_EVENT
    end
  end

  class GroupIdentifyEvent < Event
    def initialize(**attrs)
      super(**attrs)
      self.event_type = Constants::GROUP_IDENTIFY_EVENT
    end
  end

  class RevenueEvent < Event
    def initialize(**attrs)
      super(**attrs)
      self.event_type = Constants::AMP_REVENUE_EVENT
    end
  end
end
