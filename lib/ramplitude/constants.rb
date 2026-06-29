# frozen_string_literal: true

module Ramplitude
  module Constants
    SDK_LIBRARY = "ramplitude"
    SDK_VERSION_STRING = "#{SDK_LIBRARY}/#{Ramplitude::VERSION}"

    DEFAULT_ZONE = :us
    EU_ZONE      = :eu

    SERVER_URL = {
      us: { v2: "https://api2.amplitude.com/2/httpapi", batch: "https://api2.amplitude.com/batch" },
      eu: { v2: "https://api.eu.amplitude.com/2/httpapi", batch: "https://api.eu.amplitude.com/batch" },
    }.freeze

    LOGGER_NAME = "ramplitude"

    IDENTIFY_EVENT       = "$identify"
    GROUP_IDENTIFY_EVENT = "$groupidentify"

    IDENTITY_OP_SET         = "$set"
    IDENTITY_OP_SET_ONCE    = "$setOnce"
    IDENTITY_OP_ADD         = "$add"
    IDENTITY_OP_APPEND      = "$append"
    IDENTITY_OP_PREPEND     = "$prepend"
    IDENTITY_OP_PRE_INSERT  = "$preInsert"
    IDENTITY_OP_POST_INSERT = "$postInsert"
    IDENTITY_OP_REMOVE      = "$remove"
    IDENTITY_OP_UNSET       = "$unset"
    IDENTITY_OP_CLEAR_ALL   = "$clearAll"
    UNSET_VALUE             = "-"

    REVENUE_PRODUCT_ID   = "$productId"
    REVENUE_QUANTITY     = "$quantity"
    REVENUE_PRICE        = "$price"
    REVENUE_TYPE         = "$revenueType"
    REVENUE_RECEIPT      = "$receipt"
    REVENUE_RECEIPT_SIG  = "$receiptSig"
    REVENUE              = "$revenue"
    REVENUE_CURRENCY     = "$currency"
    AMP_REVENUE_EVENT    = "revenue_amount"

    MAX_PROPERTY_KEYS   = 1024
    MAX_STRING_LENGTH   = 1024
    FLUSH_QUEUE_SIZE    = 200
    FLUSH_INTERVAL_MS   = 10_000
    FLUSH_MAX_RETRIES   = 12
    CONNECTION_TIMEOUT  = 10.0
    MAX_BUFFER_CAPACITY = 20_000
  end

  module PluginType
    BEFORE      = :before
    ENRICHMENT  = :enrichment
    DESTINATION = :destination
    OBSERVE     = :observe

    ALL = [BEFORE, ENRICHMENT, DESTINATION, OBSERVE].freeze
  end
end
