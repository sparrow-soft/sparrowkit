# frozen_string_literal: true

Rails.application.configure do
  config.cache_classes = false
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false
  config.action_dispatch.show_exceptions = :none
  config.action_controller.allow_forgery_protection = false
  config.active_support.deprecation = :stderr

  # In memory, not on disk.
  #
  # Rails defaults to a FileStore, which survives between runs — so a plan
  # cached by one example was still there for the next suite, and a caching test
  # counted zero calls because the answer was already sitting in tmp. That is
  # the shape of a suite that passes locally and fails on a fresh checkout.
  config.cache_store = :memory_store
end
