# frozen_string_literal: true

# Nothing here is reachable without passing SparrowUi::Console::LoopbackGuard
# first: it is engine middleware, so it runs ahead of this route set and ahead
# of anything mounted below it.
SparrowUi::Engine.routes.draw do
  root to: "console/hub#show"

  # The hub's one setting. PATCH to the same place the hub renders, which is
  # what every panel below already does with its own.
  patch "/", to: "console/hub#update", as: :hub

  # The Inter variable font, which the inlined stylesheet points at.
  #
  # Declared BEFORE the panel mounts. A mount swallows everything beneath its
  # prefix, and a panel is free to claim any path segment it likes -- so a route
  # this engine needs has to be drawn where a panel cannot shadow it.
  get "inter.woff2", to: "console/assets#font", as: :font

  # Mounted from the registry. Every module registered itself from its own
  # engine initializer, and all engine initializers run before the route
  # reloader evaluates this file -- proven with a spike, not assumed. This gem
  # does not know what any of these panels contain.
  SparrowUi::Console.panels.each do |panel|
    # `at:` rather than the `engine => path` rocket. Mixing a rocket and a
    # label in one hash is a style standardrb rejects, and the two forms mean
    # the same thing to Mapper#mount.
    mount panel.engine, at: panel.path, as: :"#{panel.key}_panel"
  end
end
