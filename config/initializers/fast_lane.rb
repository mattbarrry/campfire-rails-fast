require "fast_lane"
require "batched_cable"
require "fast_post"

# The plain-text message fast path runs at the front of the stack everywhere, tests included, so
# the suite exercises it as production runs it.
Rails.application.config.middleware.insert_before 0, FastPost

if Rails.env.production? && ENV["FAST_LANE"] != "0"
  BatchedCable.install!

  Rails.application.config.middleware.insert_before 0, FastLane,
    database: Rails.root.join(Rails.application.config.database_configuration.dig("production", "primary", "database")).to_s
  Rails.application.config.middleware.insert_after FastPost, BatchedCable::Middleware
end
