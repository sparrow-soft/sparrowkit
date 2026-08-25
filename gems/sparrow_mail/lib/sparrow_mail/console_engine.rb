# frozen_string_literal: true

require "rails/engine"
require_relative "console/adapters"
require_relative "console/guide"

module SparrowMail
  # sparrow_mail's control panel in the SparrowKit developer console.
  #
  # Loaded only when sparrow_ui is present -- see the guard in railtie.rb --
  # and mounted only by sparrow_ui, at /sparrowkit/mail, behind the loopback
  # gate that engine's middleware applies to everything below the mount. This
  # engine does not mount itself and has no gate of its own; adding one would
  # be a second answer to a question sparrow_ui already answers for every
  # panel.
  class ConsoleEngine < ::Rails::Engine
    isolate_namespace SparrowMail

    # The panel's controller and views live under console/app, NOT app, to
    # match sparrow_auth and sparrow_pay. In those gems the location is
    # load-bearing: their main engines eager load everything under app/ on a
    # production boot, where this engine -- whose URL helpers the controller's
    # class body includes -- does not exist. sparrow_mail's main integration
    # is a Railtie with no paths, so app/ here was only ever this engine's,
    # but one layout across the three gems means nobody has to remember which
    # gem is the exception.
    config.paths.add "app/controllers", with: "console/app/controllers", eager_load: true
    config.paths["app/views"] = "console/app/views"

    # No lib/tasks. Rails::Engine#run_tasks_blocks loads every .rake file under
    # an engine's lib/tasks, and this engine resolves the same gem root as
    # SparrowMail::Railtie, which already loads them. `load` re-executes while
    # Rake APPENDS actions to an existing task, so `sparrow_mail:install` ran
    # its body twice. See the fuller note in sparrow_auth's console_engine.rb.
    config.paths["lib/tasks"] = []
  end
end
