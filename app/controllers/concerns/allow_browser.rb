module AllowBrowser
  extend ActiveSupport::Concern

  VERSIONS = { safari: 17.2, chrome: 120, firefox: 121, opera: 104, ie: false }

  included do
    allow_browser versions: VERSIONS, block: -> { render template: "sessions/incompatible_browser" }
  end
end
