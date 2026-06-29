# frozen_string_literal: true

module Ramplitude
  class Error < StandardError; end
  class InvalidAPIKeyError < Error; end
  class InvalidEventError  < Error; end
  class ConfigurationError < Error; end
end
