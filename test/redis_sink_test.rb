# frozen_string_literal: true

require_relative "test_helper"

# Minimal in-memory fake Redis that supports just the commands the sink uses.
# Lets us test the connection-pool vs bare-client paths without a server.
class FakeRedis
  def initialize
    @zsets = Hash.new { |h, k| h[k] = {} } # key => { member => score }
  end

  def zadd(key, score, member)
    new_member = !@zsets[key].key?(member)
    @zsets[key][member] = score
    new_member ? 1 : 0
  end

  def zrange(key, start, stop)
    sorted = @zsets[key].sort_by { |_m, s| s }.map(&:first)
    sorted = sorted[start..stop] || []
    sorted
  end

  def zcard(key)
    @zsets[key].size
  end

  def del(*keys)
    keys.flatten.each { |k| @zsets.delete(k) }
    keys.size
  end

  def bzpopmin(key, _timeout)
    return nil if @zsets[key].empty?
    m, s = @zsets[key].min_by { |_, score| score }
    @zsets[key].delete(m)
    [key, m, s]
  end

  def script(*); "fake-sha"; end

  def evalsha(_sha, keys:, argv:)
    key = keys.first
    now, max = argv.map(&:to_i)
    due = @zsets[key].select { |_, s| s <= now }.sort_by { |_, s| s }.first(max).map(&:first)
    due.each { |m| @zsets[key].delete(m) }
    due
  end
end

# Mimics ConnectionPool's checkout interface.
class FakePool
  attr_reader :checkouts

  def initialize(client)
    @client = client
    @checkouts = 0
  end

  def with
    @checkouts += 1
    yield @client
  end
end

class RedisSinkBareClientTest < Minitest::Test
  def setup
    @cfg   = Ramplitude::Config.new(api_key: "x", flush_queue_size: 10, flush_max_retries: 5)
    @fake  = FakeRedis.new
    @sink  = Ramplitude::Sinks::Redis.new(redis: @fake, key: "amp:test")
    @sink.setup(@cfg)
  end

  def test_round_trip_with_bare_client
    ev = Ramplitude::Event.new(event_type: "X", user_id: "u-1")
    assert_equal [true, nil], @sink.push(ev)
    assert_equal 1, @sink.size
    pulled = @sink.pull(max: 10)
    assert_equal 1, pulled.size
    assert_equal "u-1", pulled.first.user_id
    assert_equal 0, @sink.size
  end

  def test_pull_all_drains_everything
    3.times { |i| @sink.push(Ramplitude::Event.new(event_type: "X", user_id: "u#{i}")) }
    drained = @sink.pull_all
    assert_equal 3, drained.size
    assert_equal 0, @sink.size
  end
end

class RedisSinkConnectionPoolTest < Minitest::Test
  def setup
    @cfg  = Ramplitude::Config.new(api_key: "x", flush_queue_size: 10, flush_max_retries: 5)
    @fake = FakeRedis.new
    @pool = FakePool.new(@fake)
    @sink = Ramplitude::Sinks::Redis.new(redis: @pool, key: "amp:test")
    @sink.setup(@cfg)
  end

  def test_uses_pool_checkout_for_every_command
    ev = Ramplitude::Event.new(event_type: "X", user_id: "u-1")
    @sink.push(ev)
    @sink.size
    @sink.pull(max: 10)
    @sink.pull_all
    # 1 push (zadd) + 1 size + 1 pull (evalsha) + 1 pull_all = 4 checkouts
    assert_operator @pool.checkouts, :>=, 4
  end

  def test_pool_round_trip
    @sink.push(Ramplitude::Event.new(event_type: "X", user_id: "u-1"))
    @sink.push(Ramplitude::Event.new(event_type: "X", user_id: "u-2"))
    assert_equal 2, @sink.size
    pulled = @sink.pull(max: 10)
    assert_equal %w[u-1 u-2].sort, pulled.map(&:user_id).sort
  end

  def test_event_subclass_round_trip
    @sink.push(Ramplitude::IdentifyEvent.new(user_id: "u-1", user_properties: { "$set" => { "k" => "v" } }))
    pulled = @sink.pull(max: 10)
    assert_kind_of Ramplitude::IdentifyEvent, pulled.first
    assert_equal "$identify", pulled.first.event_type
  end
end
