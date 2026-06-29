# frozen_string_literal: true

require "json"

module Ramplitude
  module Sinks
    # Append-only JSONL sink. Useful for offline capture / debugging.
    # `pull` reads-and-truncates atomically by renaming the active file.
    # NOT designed for high-throughput multi-process writers.
    class File < Sink
      def initialize(path:)
        @path  = path
        @mutex = Mutex.new
      end

      def push(event, delay_ms: 0)
        return [false, "Event reached max retry #{max_retries}"] if event.retry_count >= max_retries
        line = JSON.generate({ "e" => event.to_h, "r" => event.retry_count, "delay" => delay_ms })
        @mutex.synchronize { ::File.open(@path, "a") { |f| f.puts(line) } }
        [true, nil]
      end

      def pull(max:) = pull_all.first(max)

      def pull_all
        @mutex.synchronize do
          return [] unless ::File.exist?(@path)
          lines = ::File.readlines(@path)
          ::File.delete(@path)
          lines.map { |raw| deserialize(raw) }
        end
      end

      def size = ::File.exist?(@path) ? ::File.foreach(@path).count : 0

      private

      def deserialize(raw)
        h    = JSON.parse(raw)
        wire = h.fetch("e")
        kwargs = Event::EVENT_KEY_MAPPING.each_with_object({}) do |(attr, wire_key), acc|
          acc[attr] = wire[wire_key] if wire.key?(wire_key)
        end
        ev = Event.new(**kwargs)
        ev.retry_count = h.fetch("r", 0)
        ev
      end
    end
  end
end
