# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "minitest/autorun"
require "webmock/minitest"
require "ramplitude"

# Make at_exit-registered Client#shutdown a no-op during tests — we don't want
# a stray Sidekiq-ish background thread to keep the suite alive.
module Ramplitude
  class Client
    def register_at_exit; end
  end
end
