# frozen_string_literal: true

module Ramplitude
  # Builder for user/group property operations. Mirrors Python Identify.
  class Identify
    VALID_VALUE_TYPES = [Integer, Float, String, TrueClass, FalseClass, Array, Hash].freeze

    attr_reader :user_properties

    def initialize
      @user_properties = {}
    end

    def set(key, value)         = add_operation(Constants::IDENTITY_OP_SET, key, value)
    def set_once(key, value)    = add_operation(Constants::IDENTITY_OP_SET_ONCE, key, value)
    def append(key, value)      = add_operation(Constants::IDENTITY_OP_APPEND, key, value)
    def prepend(key, value)     = add_operation(Constants::IDENTITY_OP_PREPEND, key, value)
    def pre_insert(key, value)  = add_operation(Constants::IDENTITY_OP_PRE_INSERT, key, value)
    def post_insert(key, value) = add_operation(Constants::IDENTITY_OP_POST_INSERT, key, value)
    def remove(key, value)      = add_operation(Constants::IDENTITY_OP_REMOVE, key, value)
    def unset(key)              = add_operation(Constants::IDENTITY_OP_UNSET, key, Constants::UNSET_VALUE)
    def valid?                  = !@user_properties.empty?

    def add(key, value)
      raise InvalidEventError, "$add requires a numeric value" unless value.is_a?(Numeric)
      add_operation(Constants::IDENTITY_OP_ADD, key, value)
    end

    def clear_all
      @user_properties = { Constants::IDENTITY_OP_CLEAR_ALL => Constants::UNSET_VALUE }
      self
    end

    private

    def add_operation(op, key, value)
      key = key.to_s
      # Once $clearAll is set, nothing else may be added (parity with Python).
      return self if @user_properties.key?(Constants::IDENTITY_OP_CLEAR_ALL)
      @user_properties[op] ||= {}
      # Don't overwrite if already set for this op+key (parity).
      @user_properties[op][key] = value unless @user_properties[op].key?(key)
      self
    end
  end
end
