# Example: web processes only enqueue events to Redis; a Sidekiq job
# bulk-flushes them to Ramplitude on a schedule.
#
# config/initializers/amplitude.rb
#
#   Ramplitude.configure do |c|
#     c.api_key  = ENV.fetch("AMPLITUDE_API_KEY")
#     c.sink     = Ramplitude::Sinks::Redis.new(redis: $redis, key: "amp:events")
#     c.uploader = Ramplitude::Uploaders::Null.new  # web doesn't drain
#     c.use_batch = true
#   end

require "sidekiq"
require "ramplitude"

class AmplitudeFlushJob
  include Sidekiq::Job
  sidekiq_options queue: :amplitude, retry: false

  def perform
    Ramplitude::BulkFlusher.new(
      api_key: ENV.fetch("AMPLITUDE_API_KEY"),
      sink:    Ramplitude::Sinks::Redis.new(redis: $redis, key: "amp:events"),
      config:  Ramplitude::Config.new(use_batch: true, flush_queue_size: 1000),
    ).drain(max_batches: 50)
  end
end

# Schedule with sidekiq-cron / sidekiq-scheduler / whenever — every minute is
# usually plenty for analytics traffic.
