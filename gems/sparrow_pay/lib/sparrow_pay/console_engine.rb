# frozen_string_literal: true

require "rails/engine"
require "sparrow_pay/console/processors"
require "sparrow_pay/console/report"
require "sparrow_pay/console/guide"

module SparrowPay
  # sparrow_pay's control panel in the SparrowKit developer console.
  #
  # Loaded only when sparrow_ui is present -- see the guard in engine.rb -- and
  # mounted only by sparrow_ui, at /sparrowkit/pay, behind the loopback gate
  # that engine's middleware applies to everything below the mount. This engine
  # does not mount itself and has no gate of its own; adding one would be a
  # second answer to a question sparrow_ui already answers for every panel.
  #
  # A SECOND engine beside SparrowPay::Engine, rather than a route added to it,
  # for the same reason sparrow_auth has two. The billing engine is mounted by
  # the host and serves customers; this one is mounted by the console, in
  # development only, and serves the developer. One engine cannot be both: a
  # panel route hanging off the billing engine would be reachable in production,
  # which is precisely what the console must never be.
  class ConsoleEngine < ::Rails::Engine
    # The same namespace SparrowPay::Engine already isolated, which is fine:
    # Rails::Engine#isolate_namespace only installs its helper methods on the
    # module `unless mod.respond_to?(:railtie_namespace)`, so the second call
    # sets this engine's own default route scope and leaves the existing wiring
    # alone.
    #
    # What it does NOT do is give this engine's controllers this engine's URL
    # helpers -- see the controller, which includes them itself and says why.
    isolate_namespace SparrowPay

    # The panel's controller and views live under console/app, NOT app. The
    # gem root's app/ belongs to SparrowPay::Engine, whose `app` path eager
    # loads every subdirectory on a production boot -- and the controller's
    # class body includes this engine's URL helpers, a constant that only
    # exists where sparrow_ui does. Under app/ the panel therefore booted
    # every production host straight into `uninitialized constant
    # SparrowPay::ConsoleEngine`. Here, the files are on no path at all until
    # this engine is required, and this engine is required behind the
    # sparrow_ui guard in engine.rb.
    config.paths.add "app/controllers", with: "console/app/controllers", eager_load: true
    config.paths["app/views"] = "console/app/views"

    # Both engines are declared under gems/sparrow_pay/lib, so Rails resolves
    # the same gem root for both, and by default both would claim
    # config/routes.rb. The application's routes reloader keeps a flat list of
    # files and loads each one, so the file would be evaluated twice per reload
    # -- drawing SparrowPay::Engine's routes a second time and raising on the
    # first named route it had already defined -- while this engine ended up
    # with no routes at all.
    config.paths["config/routes.rb"] = "config/console_routes.rb"

    # And no lib/tasks either. Both engines here resolve the same gem root, so
    # both loaded the same .rake files -- and `load` re-executes while Rake
    # APPENDS actions to an existing task, so `sparrow_pay:install` ran its body
    # once per load. See the fuller note in sparrow_auth's console_engine.rb.
    config.paths["lib/tasks"] = []
  end
end
