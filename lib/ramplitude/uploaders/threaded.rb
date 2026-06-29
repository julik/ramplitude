# frozen_string_literal: true

module Ramplitude
  module Uploaders
    # Default uploader. Mirrors Python Workers:
    #   - one consumer thread waits on sink.wait then pulls batches
    #   - a small worker pool POSTs batches in parallel
    class Threaded < Uploader
      def initialize(pool_size: 4)
        @pool_size  = pool_size
        @work_queue = Queue.new
        @workers    = []
        @started    = false
        @consumer   = nil
        @stopped    = false
        @lifecycle_mutex = Mutex.new
      end

      def start
        @lifecycle_mutex.synchronize do
          return if @started || @stopped
          @started = true
          @workers = Array.new(@pool_size) { spawn_worker }
          @consumer = Thread.new { consumer_loop }
        end
      end

      def flush
        events = @sink.pull_all
        return NoopFuture.new if events.empty?
        ensure_started
        future = ThreadedFuture.new(events.size)
        events.each_slice(@config.flush_queue_size) do |batch|
          @work_queue << [batch, future]
        end
        future
      end

      def stop
        @lifecycle_mutex.synchronize do
          return if @stopped
          @stopped = true
        end
        flush.wait
        @pool_size.times { @work_queue << :stop }
        @workers.each(&:join)
        @consumer&.kill # wakes it out of sink.wait
      end

      private

      def ensure_started = (start unless @started)

      def spawn_worker
        Thread.new do
          loop do
            item = @work_queue.pop
            break if item == :stop
            batch, future = item
            begin
              send_one(batch)
            rescue StandardError => e
              @config.logger&.error("Uploader worker error: #{e.class}: #{e.message}")
            ensure
              future&.complete_one
            end
          end
        end
      end

      def consumer_loop
        until @stopped
          break if @sink.size.nil? # external sink doesn't want polling
          if @sink.size > 0
            batch = @sink.pull(max: @config.flush_queue_size)
            if batch.any?
              future = ThreadedFuture.new(1)
              @work_queue << [batch, future]
            end
          end
          @sink.wait(timeout_ms: @config.flush_interval_ms)
        end
      rescue StandardError => e
        @config.logger&.error("Consumer thread crashed: #{e.message}")
      end
    end

    class ThreadedFuture
      def initialize(count)
        @remaining = count
        @mutex     = Mutex.new
        @cv        = ConditionVariable.new
      end

      def complete_one
        @mutex.synchronize do
          @remaining -= 1
          @cv.broadcast if @remaining <= 0
        end
      end

      def wait
        @mutex.synchronize { @cv.wait(@mutex) while @remaining > 0 }
        nil
      end

      def value = nil
    end
  end
end
