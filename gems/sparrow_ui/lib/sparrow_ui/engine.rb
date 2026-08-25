# frozen_string_literal: true

require "rails/engine"
require_relative "console/loopback_guard"

module SparrowUi
  # Registers the console's views and its compiled stylesheet with a host, and
  # carries the console's routes behind the gate.
  #
  # The gem ships no components and no view helpers. A module's panel writes
  # ordinary Tailwind classes; the markup decides how it looks.
  #
  # This engine does NOT mount itself. A host mounts it, inside a
  # `Rails.env.development?` guard, and the middleware below refuses anything
  # that did not arrive on a loopback socket. An engine that mounted itself
  # would be a route a customer could reach in production, which is exactly
  # what this gem must never be.
  class Engine < ::Rails::Engine
    isolate_namespace SparrowUi

    # Every request to anything mounted under this engine passes through here
    # first, including panels registered by other gems.
    middleware.use SparrowUi::Console::LoopbackGuard

    # Propshaft and Sprockets both read this. A host with neither still works:
    # the console inlines the stylesheet rather than linking it.
    initializer "sparrow_ui.assets" do |app|
      paths = app.config.respond_to?(:assets) ? app.config.assets&.paths : nil
      next unless paths

      paths << root.join("app/assets/stylesheets").to_s
      paths << root.join("app/assets/fonts").to_s
    end
  end
end
