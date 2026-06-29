# frozen_string_literal: true

module Ramplitude
  module Utils
    module_function

    def current_milliseconds = (Process.clock_gettime(Process::CLOCK_REALTIME) * 1000).to_i

    def truncate(obj)
      case obj
      when Hash
        return {} if obj.size > Constants::MAX_PROPERTY_KEYS
        obj.transform_values { |v| truncate(v) }
      when Array
        obj.map { |v| truncate(v) }
      when String
        obj.length > Constants::MAX_STRING_LENGTH ? obj[0, Constants::MAX_STRING_LENGTH] : obj
      else
        obj
      end
    end
  end
end
