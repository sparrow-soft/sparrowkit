# frozen_string_literal: true

require "rails/engine"
require "rodauth-rails"
require "sparrow_mail"

module SparrowAuth
  # The mountable engine.
  #
  # `isolate_namespace` keeps the engine's models, controllers and routes under
  # SparrowAuth, so mounting it cannot collide with a host application's own
  # Account or Invitation class. That matters more here than in most engines:
  # applications adopting this already have their own user-shaped models, and a
  # silent collision in an auth engine is the worst place for one.
  class Engine < ::Rails::Engine
    isolate_namespace SparrowAuth

    config.generators do |g|
      g.test_framework :rspec
      g.orm :active_record, primary_key_type: :bigint
    end

    # Migrations ship with the engine and are COPIED into the host, by
    # `rails sparrow_auth:install:migrations` or by the installer that wraps it.
    # A host application owns its schema.
    #
    # There was an initializer here adding this engine's db/migrate to the
    # host's migration paths, and it did the opposite of what the comment above
    # it claimed. A host then had every migration TWICE -- once as the copy in
    # its own db/migrate, once from the gem -- and `bin/rails db:migrate`, the
    # most ordinary command in Rails, died on DuplicateMigrationNameError.
    #
    # Engines pick one convention or the other. Copying is ours, because it is
    # what lets a host edit, reorder or squash the migrations it now owns, and
    # what makes `db:migrate` mean the same thing it means in every other Rails
    # application. Adding the path as well is not belt and braces; it is two
    # copies of the same trousers.
    #
    # Found by installing into a real application and running db:migrate. Every
    # suite here passed throughout: the dummies migrate from explicit engine
    # paths and never exercise a host's configured ones.

    # What is in `sparrow_auth:` in the host's credentials, applied over the
    # defaults.
    #
    # This is what makes the console panel work at all. Without it the panel is
    # a form that writes a file nobody reads: values save, the page shows them
    # saved, and the running application never sees one.
    #
    # No mapping table and no translation. A credentials key sets the
    # Configuration attribute of the same name, so `webauthn_rp_id:` in the
    # YAML is `config.webauthn_rp_id`, and a developer can guess either
    # direction without being told. Anything that is not a settable attribute
    # is ignored rather than raising -- credentials are hand-editable, and a
    # typo there should not stop an application booting.
    #
    # Runs BEFORE config/initializers, because engine initializers do. So an
    # application that sets something in config/initializers/sparrow_auth.rb
    # still wins: the console is for getting started, and a panel that silently
    # overrode a line somebody wrote on purpose would be a bug reported as "my
    # initializer stopped working".
    initializer "sparrow_auth.credentials", before: :load_config_initializers do
      SparrowAuth.configure do |config|
        SparrowAuth.credentials.each do |name, value|
          writer = :"#{name}="
          config.public_send(writer, value) if config.respond_to?(writer)
        end
      end
    end

    # Registration lives below, in on_load(:before_configuration), NOT here.
    #
    # A second registration stood in this spot doing the same job from a plain
    # `initializer`. It was correct for the design it was written for -- one
    # that mounted each panel directly in the host's routes -- but mounting
    # every panel under /sparrowkit means sparrow_ui draws those mounts from
    # the registry, and an engine registering after its routes file is read
    # contributes no routes while still appearing on the hub.
    #
    # Keeping both was caught the loudest possible way: Console.register
    # refuses a duplicate key, so the application would not boot.

    # NO `rake_tasks do load ... end` HERE, and that is the fix rather than an
    # omission. Rails::Engine#run_tasks_blocks already loads every .rake file
    # under lib/tasks, so an explicit load is a SECOND load of the same file --
    # and `load` re-executes it while Rake APPENDS actions to a task that
    # already exists. The task then runs its body once per load.
    #
    # It was worse than doubled here. This gem ships two engines from one
    # directory, and both resolved the same lib/tasks, so `sparrow_auth:install`
    # had three actions and printed its report three times. Found by installing
    # the bundle into a real Rails application; nothing in this repository's own
    # suites could see it, because they never load an application's rake tasks.
    #
    # ConsoleEngine now declares no lib/tasks path at all -- see console_engine.rb.

    # The Roda application Rodauth runs inside. Shipping it from the engine is
    # the whole reason Rodauth was chosen over Devise: the auth configuration is
    # one object, so it packages, rather than a set of model mixins and
    # initializers a host has to assemble correctly.
    initializer "sparrow_auth.rodauth" do
      Rodauth::Rails.configure do |config|
        config.app = "SparrowAuth::RodauthApp"
      end
    end

    # The control panel, when there is a console to put it in.
    #
    # NOT an `initializer` block, which is where a registration like this
    # belongs and where it cannot go. Registering is only half the job: the
    # panel is a Rails::Engine, and an engine defined once the application has
    # started running initializers is too late to contribute any of its own --
    # its routes and autoload paths are never wired up, and the mount answers
    # 404 while looking registered. The engine therefore has to exist before
    # `initialize!`, and this is the last hook that still is: it fires when the
    # host's Application class is defined, in config/application.rb, which every
    # Rails application evaluates after Bundler.require. So the guard below is
    # asked at the first moment its answer is trustworthy.
    #
    # The guard is what keeps the panel free in production. sparrow_ui is a
    # development-group gem, so on a production box the constant is undefined,
    # nothing is required, no second engine exists, and sparrow_auth is the auth
    # engine and nothing else.
    ActiveSupport.on_load(:before_configuration) do
      next unless defined?(::SparrowUi::Console)

      require "sparrow_auth/console_engine"

      ::SparrowUi::Console.register(
        key: :auth,
        setup_order: 20,
        name: "Authentication",
        # For the header's nav, where three panels share one row.
        short_name: "Auth",
        summary: "Passkeys, ways in, auth mail",
        engine: SparrowAuth::ConsoleEngine,
        # A lambda, not a value: it is called on each render of the hub, so the
        # badge reflects the credentials as they are now rather than as they
        # were when the application booted -- which for a page whose whole
        # purpose is editing them would be wrong within a minute of arriving.
        status: -> { SparrowAuth::Console::Report.new.status },
        guide: -> { SparrowAuth::Console::Guide.new.to_h }
      )
    end
  end
end
