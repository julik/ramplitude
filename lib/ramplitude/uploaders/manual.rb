# frozen_string_literal: true

module Ramplitude
  module Uploaders
    # Sends only when you explicitly call `flush`. No background thread.
    # Useful in scripts, tests, or when you drive a cron from outside.
    class Manual < Uploader
      def start = nil
      def stop  = flush
    end
  end
end
