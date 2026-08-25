# frozen_string_literal: true

Rails.application.routes.draw do
  # Mounted unconditionally, unlike a real host.
  #
  # The installer writes `if Rails.env.development?` around this in an
  # application it does not own. Here the whole application is the console, so
  # the guard would only be a way to boot into an empty 404 by forgetting an
  # environment variable. The engine's own middleware still refuses anything
  # that is not local development, which is the check that matters.
  mount SparrowUi::Engine => "/sparrowkit"

  root to: redirect("/sparrowkit")
end
