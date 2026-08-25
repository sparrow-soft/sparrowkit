# frozen_string_literal: true

require "rails/engine"
require "sparrow_auth/console/report"
require "sparrow_auth/console/guide"

module SparrowAuth
  # sparrow_auth's control panel in the SparrowKit developer console.
  #
  # Loaded only when sparrow_ui is present -- see the guard in engine.rb -- and
  # mounted only by sparrow_ui, at /sparrowkit/auth, behind the loopback gate
  # that engine's middleware applies to everything below the mount. This engine
  # does not mount itself and has no gate of its own; adding one would be a
  # second answer to a question sparrow_ui already answers for every panel.
  #
  # A SECOND engine beside SparrowAuth::Engine, rather than a route added to it.
  # The auth engine is mounted by the host at /auth and serves end users; this
  # one is mounted by the console, in development only, and serves the
  # developer. One engine cannot be both: a panel route hanging off the auth
  # engine would be reachable at /auth/... in production, which is precisely
  # what the console must never be.
  class ConsoleEngine < ::Rails::Engine
    # The same namespace the auth engine already isolated, and that is fine:
    # Rails::Engine#isolate_namespace only installs its helper methods on the
    # module `unless mod.respond_to?(:railtie_namespace)`, so the second call
    # sets this engine's own default route scope and leaves SparrowAuth's
    # existing wiring alone.
    #
    # What it does NOT do is give this engine's controllers this engine's URL
    # helpers -- see the controller, which includes them itself and says why.
    isolate_namespace SparrowAuth

    # The panel's controller and views live under console/app, NOT app. The
    # gem root's app/ belongs to SparrowAuth::Engine, whose `app` path eager
    # loads every subdirectory on a production boot -- and the controller's
    # class body includes this engine's URL helpers, a constant that only
    # exists where sparrow_ui does. Under app/ the panel therefore booted
    # every production host straight into `uninitialized constant
    # SparrowAuth::ConsoleEngine`. Here, the files are on no path at all until
    # this engine is required, and this engine is required behind the
    # sparrow_ui guard in engine.rb.
    config.paths.add "app/controllers", with: "console/app/controllers", eager_load: true
    config.paths["app/views"] = "console/app/views"

    # Both engines are declared under gems/sparrow_auth/lib, so Rails resolves
    # the same gem root for both, and by default both would claim
    # config/routes.rb. The application's routes reloader keeps a flat list of
    # files and loads each one, so the file would be evaluated twice per reload
    # -- drawing SparrowAuth::Engine's routes a second time and raising on the
    # first named route it had already defined -- while this engine ended up
    # with no routes at all.
    config.paths["config/routes.rb"] = "config/console_routes.rb"

    # And no lib/tasks either, for the same reason and a worse symptom.
    #
    # Rails::Engine#run_tasks_blocks loads every .rake file under an engine's
    # lib/tasks. Both engines here resolve the same gem root, so both loaded the
    # same files -- and `load` re-executes while Rake APPENDS actions to a task
    # that already exists, so the task's body ran once per load.
    # `sparrow_auth:install` printed its entire report three times.
    #
    # The rake tasks belong to the gem, not to the console, so this engine
    # claims none of them.
    config.paths["lib/tasks"] = []
  end
end
