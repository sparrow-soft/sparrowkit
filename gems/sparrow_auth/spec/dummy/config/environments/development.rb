# frozen_string_literal: true

# The dummy in development, which exists for one thing: opening the SparrowKit
# console at /sparrowkit and clicking through the auth panel the way a developer
# installing this gem would.
#
# It has to be *development* specifically. sparrow_ui's gate asks
# `Rails.env.development?` before anything below the mount is routed, so the
# smoke environment -- which is otherwise the one for poking at this application
# by hand -- answers 404 for the console and always will.
#
#   bin/rails server -e development -p 3542   # from spec/dummy
Rails.application.configure do
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.action_controller.allow_forgery_protection = true

  # Every failure explains itself on the page. The application silences its
  # logger globally, which is right for the suite and would otherwise turn a
  # perfectly clear error into a blank 500.
  config.action_dispatch.show_exceptions = :all
  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :error

  config.active_support.deprecation = :silence
end
