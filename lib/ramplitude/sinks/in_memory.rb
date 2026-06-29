# frozen_string_literal: true

module Ramplitude
  module Sinks
    # Default in-process sink. Mirrors the Python InMemoryStorage algorithm:
    #   - `ready_queue` for events due now
    #   - `buffer_data` for delayed events, sorted by ready-at timestamp,
    #     binary-inserted on push
    # Thread-safe via Mutex + ConditionVariable; `wait` unblocks the consumer
    # thread either when a flush_queue_size worth of events is ready or after
    # the configured flush interval.
    class InMemory < Sink
      def initialize
        @ready_queue = []
        @buffer_data = []   # Array of [ready_at_ms, event]
        @total       = 0
        @mutex       = Mutex.new
        @cv          = ConditionVariable.new
      end

      def push(event, delay_ms: 0)
        return [false, "Sink full; retry temporarily disabled"] if event.retry_count > 0 && @total >= Constants::MAX_BUFFER_CAPACITY
        return [false, "Event reached max retry #{max_retries}"] if event.retry_count >= max_retries

        total_delay = delay_ms + retry_delay(event.retry_count)
        insert_event(total_delay, event)
        [true, nil]
      end

      def pull(max:)
        now = Utils.current_milliseconds
        @mutex.synchronize do
          result = @ready_queue.shift(max)
          while result.size < max && !@buffer_data.empty? && @buffer_data.first[0] <= now
            result << @buffer_data.shift[1]
          end
          @total -= result.size
          result
        end
      end

      def pull_all
        @mutex.synchronize do
          @total = 0
          all = @ready_queue + @buffer_data.map { |(_, e)| e }
          @ready_queue = []
          @buffer_data = []
          all
        end
      end

      def size = @mutex.synchronize { @total }

      # Block consumer thread. Returns when notified by push (queue >= flush_queue_size)
      # or after timeout_ms.
      def wait(timeout_ms:) = @mutex.synchronize { @cv.wait(@mutex, timeout_ms / 1000.0) }

      # Time the consumer should sleep before the next pull attempt.
      def wait_time
        @mutex.synchronize do
          return 0 unless @ready_queue.empty?
          return @config.flush_interval_ms if @buffer_data.empty?
          [@buffer_data.first[0] - Utils.current_milliseconds, @config.flush_interval_ms].min
        end
      end

      private

      def insert_event(delay, event)
        now = Utils.current_milliseconds
        @mutex.synchronize do
          # Promote already-due delayed events.
          while !@buffer_data.empty? && @buffer_data.first[0] <= now
            @ready_queue << @buffer_data.shift[1]
          end
          if delay <= 0
            @ready_queue << event
          else
            ts = now + delay
            # Binary insert by ts.
            lo, hi = 0, @buffer_data.size - 1
            while lo <= hi
              mid = (lo + hi) / 2
              if @buffer_data[mid][0] > ts
                hi = mid - 1
              else
                lo = mid + 1
              end
            end
            @buffer_data.insert(lo, [ts, event])
          end
          @total += 1
          @cv.signal if @ready_queue.size >= @config.flush_queue_size
        end
      end

      def retry_delay(n)
        return 0 if n <= 0
        n > @config.flush_max_retries ? 3200 : 100 * (2 ** ((n - 1) / 2))
      end
    end
  end
end
