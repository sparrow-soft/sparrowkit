# frozen_string_literal: true

require "rails/engine"
require "sparrow_auth"
require "pay"

module SparrowPay
  # A mountable engine, for the same reason sparrow_auth is one: the billing
  # pages, the migrations and the configuration travel together or a host has to
  # assemble them correctly, and eventually one of them will not.
  class Engine < ::Rails::Engine
    isolate_namespace SparrowPay

    config.generators do |g|
      g.test_framework :rspec
      g.orm :active_record, primary_key_type: :bigint
    end

    # NO `rake_tasks do load ... end` HERE. Rails::Engine#run_tasks_blocks
    # already loads everything under lib/tasks, and `load` re-executes while
    # Rake appends actions to an existing task -- so an explicit load makes the
    # task run its body twice. With two engines sharing this gem's root it was
    # three times. See the note in engine.rb of sparrow_auth.

    # Migrations ship with the engine and are COPIED into the host, by
    # `rails sparrow_pay:install:migrations` or by the installer that wraps it.
    # A host application owns its schema.
    #
    # There was an initializer here adding this engine's db/migrate to the
    # host's migration paths as well, which gave a host every migration twice
    # and broke `bin/rails db:migrate` outright. See the fuller note in
    # sparrow_auth's engine.rb.

    # What the console panel saved, applied over this gem's defaults.
    #
    # Without this the panel is a form that writes a file nobody reads. It runs
    # BEFORE the host's own initializer -- engine initializers do -- so an
    # application that sets something in config/initializers/sparrow_pay.rb
    # still wins. That is the right way round: the console is for getting
    # started, and a panel that silently overrode a line somebody wrote on
    # purpose would be a bug reported as "my initializer stopped working".
    #
    # Only this gem's own settings. The PROCESSOR's keys are not read here at
    # all: Pay reads those itself, from the top of the credentials file, which
    # is why the panel writes them there.
    initializer "sparrow_pay.credentials", before: :load_config_initializers do
      stored = SparrowPay.credentials
      next if stored.empty?

      SparrowPay.configure do |config|
        config.default_processor = stored[:default_processor].presence&.to_sym
        config.allow_fake_processor = !!stored[:allow_test_processor]
      end
    end

    # Keep the copied columns current from Pay's webhook events.
    #
    # After initialization so a host's own subscribers are already in place, and
    # so this is not competing with Pay's own setup for ordering.
    config.after_initialize do
    end

    # The control panel, when there is a console to put it in.
    #
    # NOT an `initializer` block, which is where a registration like this
    # belongs and where it cannot go. Registering is only half the job: the
    # panel is a Rails::Engine, and an engine defined once the application has
    # started running initializers is too late to contribute any of its own --
    # its views, routes and autoload paths are never wired up, and the mount
    # answers 404 while looking registered. The engine therefore has to exist
    # before `initialize!`, and this is the last hook that still is: it fires
    # when the host's Application class is defined, in config/application.rb,
    # which every Rails application evaluates after Bundler.require.
    #
    # The guard is what keeps the panel free in production. sparrow_ui is a
    # development-group gem, so on a production box the constant is undefined,
    # nothing is required, no second engine exists, and sparrow_pay is the
    # billing engine and nothing else.
    ActiveSupport.on_load(:before_configuration) do
      next unless defined?(::SparrowUi::Console)

      require "sparrow_pay/console_engine"

      ::SparrowUi::Console.register(
        key: :pay,
        setup_order: 30,
        name: "Payments",
        # For the header's nav, where three panels share one row.
        short_name: "Pay",
        summary: "Processor, API keys, who may bill",
        engine: SparrowPay::ConsoleEngine,
        # A lambda, not a value: it is called on each render of the hub, so the
        # badge reflects the credentials as they are now rather than as they
        # were when the application booted -- which for a page whose whole
        # purpose is editing them would be wrong within a minute of arriving.
        status: -> { SparrowPay::Console::Report.new.status },
        guide: -> { SparrowPay::Console::Guide.new.to_h }
      )
    end

    # The organization becomes the billable entity, and nothing else does.
    #
    # Done here rather than asking hosts to add `pay_customer` to a model they
    # do not own — SparrowAuth::Organization ships in another gem. It also
    # settles the question by construction: there is no way for an application
    # to accidentally make an account the customer, because the engine never
    # offers that.
    initializer "sparrow_pay.billable" do
      ActiveSupport.on_load(:active_record) do
        SparrowAuth::Organization.include(SparrowPay::Billable)
      end
    end
  end
end
