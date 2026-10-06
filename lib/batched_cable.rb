# Action Cable broadcasts made while serving a request are collected and published to Redis in one
# pipelined round trip once the response has been written (Puma's rack.after_reply), instead of one
# round trip each, in line, on the adapter's single shared connection.
#
# Outside a request (jobs, console) or with a non-Redis adapter (tests), broadcasts go out as usual.
module BatchedCable
  # Collects the broadcasts made in the block and publishes them together afterwards. Adapters
  # without batching (the test adapter) just broadcast as usual.
  def self.batch
    pubsub = ActionCable.server.pubsub
    return yield unless pubsub.respond_to?(:publish_batch)

    previous, batch = Thread.current[:batched_cable], []
    Thread.current[:batched_cable] = batch
    begin
      yield
    ensure
      Thread.current[:batched_cable] = previous
      pubsub.publish_batch(batch) if previous.nil? && batch.any?
      previous&.concat(batch)
    end
  end

  module Adapter
    def broadcast(channel, payload)
      if (batch = Thread.current[:batched_cable])
        batch << [ channel, payload ]
      else
        redis_connection_for_broadcasts.publish(channel, payload)
      end
    end

    def publish_batch(batch)
      redis_connection_for_broadcasts.pipelined do |pipeline|
        batch.each { |channel, payload| pipeline.publish(channel, payload) }
      end
    end
  end

  class Middleware
    def initialize(app)
      @app = app
    end

    def call(env)
      return @app.call(env) if env["REQUEST_METHOD"] == "GET" || env["REQUEST_METHOD"] == "HEAD"

      batch = Thread.current[:batched_cable] = []
      begin
        response = @app.call(env)
      ensure
        Thread.current[:batched_cable] = nil
      end

      if batch.any?
        flush = -> { ActionCable.server.pubsub.publish_batch(batch) }
        if (after_reply = env["rack.after_reply"])
          after_reply << flush
        else
          flush.call
        end
      end

      response
    end
  end
end

def BatchedCable.install!
  require "action_cable/subscription_adapter/redis"

  # Defined on the class itself so ChannelPrefix (prepended) still prefixes the channel first.
  ActionCable::SubscriptionAdapter::Redis.class_eval do
    define_method(:broadcast, BatchedCable::Adapter.instance_method(:broadcast))
    define_method(:publish_batch, BatchedCable::Adapter.instance_method(:publish_batch))
  end
end
