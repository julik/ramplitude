# frozen_string_literal: true

module Ramplitude
  module Uploaders
    # Does nothing. Pair with a durable sink (e.g. Redis) when an external
    # process (Sidekiq, ActiveJob, cron) drains the sink via BulkFlusher.
    class Null < Uploader
      def start = nil
      def flush = NoopFuture.new
      def stop  = NoopFuture.new
    end
  end
end
