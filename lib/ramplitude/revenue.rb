# frozen_string_literal: true

module Ramplitude
  # Builder for revenue events. Mirrors Python Revenue.
  class Revenue
    attr_accessor :price, :quantity, :product_id, :revenue_type,
                  :receipt, :receipt_signature, :revenue, :currency,
                  :event_properties

    def initialize(price:, quantity: 1, product_id: nil, revenue_type: nil,
                   receipt: nil, receipt_signature: nil, revenue: nil,
                   currency: nil, event_properties: nil)
      @price             = price
      @quantity          = quantity
      @product_id        = product_id
      @revenue_type      = revenue_type
      @receipt           = receipt
      @receipt_signature = receipt_signature
      @revenue           = revenue
      @currency          = currency
      @event_properties  = event_properties
    end

    def set_receipt(receipt, signature)
      @receipt = receipt
      @receipt_signature = signature
      self
    end

    def valid? = @price.is_a?(Numeric)

    def event_properties_hash
      props = @event_properties ? @event_properties.dup : {}
      props[Constants::REVENUE_PRICE]       = @price
      props[Constants::REVENUE_QUANTITY]    = @quantity
      props[Constants::REVENUE_PRODUCT_ID]  = @product_id   if @product_id
      props[Constants::REVENUE_TYPE]        = @revenue_type if @revenue_type
      props[Constants::REVENUE_RECEIPT]     = @receipt      if @receipt
      props[Constants::REVENUE_RECEIPT_SIG] = @receipt_signature if @receipt_signature
      props[Constants::REVENUE]             = @revenue      if @revenue
      props[Constants::REVENUE_CURRENCY]    = @currency     if @currency
      props
    end

    def to_revenue_event = RevenueEvent.new(event_properties: event_properties_hash)
  end
end
