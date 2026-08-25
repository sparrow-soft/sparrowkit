# frozen_string_literal: true

Rails.application.configure do
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false

  # Forgery protection ON, unlike the test environment. The smoke run drives the
  # real forms over real HTTP, so it exercises the CSRF path an application will
  # actually be behind. A run with protection disabled would prove the flow
  # works in a configuration nobody deploys.
  config.action_controller.allow_forgery_protection = true

  # Show the exception, always.
  #
  # `:rescuable` re-raises anything that is not a rescuable framework error, and
  # with the application's logger pointed at IO::NULL that arrives in the browser
  # as a 500 with an empty body — a black screen carrying no information at all.
  # A perfectly clear error ("no from address for auth mail. Set ...") was
  # invisible for exactly that reason.
  #
  # This environment exists to be poked at by hand, so every failure should
  # explain itself on the page. `:all` renders the debug page instead of
  # re-raising, and consider_all_requests_local above makes it the detailed one.
  config.action_dispatch.show_exceptions = :all

  # And somewhere to read them afterwards. The dummy application silences its
  # logger globally, which is right for the suite and wrong here.
  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :error

  config.active_support.deprecation = :silence
end
