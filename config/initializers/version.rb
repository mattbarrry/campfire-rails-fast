Rails.application.config.app_version = ENV["APP_VERSION"].presence || ENV["GIT_REVISION"].presence || "0"
Rails.application.config.git_revision = ENV["GIT_REVISION"]
