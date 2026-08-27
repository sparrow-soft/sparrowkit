# frozen_string_literal: true

module SparrowMail
  # Wires the gem into a Rails application. Loaded only when Rails is present,
  # which is what lets sparrow_mail depend on `mail` alone and still integrate
  # cleanly with ActionMailer.
  class Railtie < ::Rails::Railtie
    DELIVERY_METHOD = :sparrow_mail

    # sparrow_mail:install
    rake_tasks do
      load File.expand_path("../tasks/sparrow_mail_install.rake", __dir__)
    end

    # The installer writes NO SETTINGS FILE, deliberately.
    #
    # There was one, and it wrote config/initializers/sparrow_mail.rb with a
    # commented example per provider. That was the right shape when the only
    # way to configure mail was environment variables. It is the wrong shape
    # now: the control panel writes the same settings to encrypted credentials,
    # config/initializers runs AFTER those are read, and the generated file
    # assigned `config.adapter` unconditionally -- so a developer who followed
    # the README and then used the panel had their provider silently reset to
    # the test adapter on the next boot, and every message went nowhere with no
    # error at all.
    #
    # Two ways to set one value is the problem; deleting one of them is the
    # fix. The panel is the way, http://localhost:3000/sparrowkit/mail, and
    # `bin/rails credentials:edit` is the same file by hand.

    # Registration lives below, in on_load(:before_configuration), NOT in an
    # initializer.
    #
    # There was a second registration here doing the same job from a plain
    # `initializer`, and it worked in the design it was written for: that one
    # mounted each panel directly in the host's routes file, so route drawing
    # never depended on when registration happened. Mounting every panel under
    # /sparrowkit does depend on it -- sparrow_ui draws the mounts from the
    # registry, and an engine that registers after its routes file has been
    # read contributes no routes at all while still appearing on the hub.
    #
    # Having both was caught the loudest possible way: Console.register refuses
    # a duplicate key, so the application would not boot.

    # What is in `sparrow_mail:` in the host's credentials, applied over the
    # defaults.
    #
    # This is what makes the console panel work at all. Without it the panel is
    # a form that writes a file nobody reads: values save, the page shows them
    # saved, and the running application never sends through the provider it
    # says it is using.
    #
    #   sparrow_mail:
    #     default_from: Acme <hello@acme.test>
    #     transactional:
    #       adapter: postmark
    #       api_key: ...
    #     marketing:
    #       adapter: mailgun
    #       api_key: ...
    #
    # The shape mirrors what this gem already models, so there is nothing to
    # learn twice: `transactional` is the default adapter and its settings,
    # and every other key is a stream declared with `config.stream`.
    #
    # Runs BEFORE config/initializers, because railtie initializers do. This
    # gem ships no initializer, so nothing of ours competes; an application
    # that writes its own by hand still wins, which is the right way round for
    # a line somebody chose to write.
    initializer "sparrow_mail.credentials", before: :load_config_initializers do
      SparrowMail.apply_credentials!
    end

    initializer "sparrow_mail.delivery_method" do
      ActiveSupport.on_load(:action_mailer) do
        ActionMailer::Base.add_delivery_method(
          SparrowMail::Railtie::DELIVERY_METHOD,
          SparrowMail::DeliveryMethod
        )

        # RetryableDeliveryJob subclasses ActionMailer::MailDeliveryJob, so it
        # cannot be required until ActionMailer is -- this hook is the first
        # point that is guaranteed true.
        require "sparrow_mail/retryable_delivery_job"
      end
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
    # which every Rails application evaluates after Bundler.require. So the
    # guard below is asked at the first moment its answer is trustworthy.
    #
    # The guard is what keeps the panel free in production. sparrow_ui is a
    # development-group gem, so on a production box the constant is undefined,
    # nothing is required, no engine exists, and sparrow_mail is the delivery
    # layer and nothing else.
    ActiveSupport.on_load(:before_configuration) do
      next unless defined?(::SparrowUi::Console)

      require "sparrow_mail/console_engine"

      ::SparrowUi::Console.register(
        key: :mail,
        setup_order: 10,
        name: "Mail",
        summary: "Provider, API key, sender address",
        engine: SparrowMail::ConsoleEngine,
        # A lambda, not a value: it is called on each render of the hub, so the
        # badge reflects the credentials as they are now rather than as they
        # were when the application booted -- which for a page whose whole
        # purpose is editing them would be wrong within a minute of arriving.
        status: -> { SparrowMail::Console::Report.new.status },
        guide: -> { SparrowMail::Console::Guide.new.to_h }
      )
    end

    # Everything below runs after initialization so that an application's own
    # initializer wins. These are fallbacks, not policy.
    config.after_initialize do
      SparrowMail.configure do |config|
        config.logger ||= Rails.logger

        # The test adapter in the test environment, unless the application says
        # otherwise. A suite that silently posts to a real provider is a bad
        # day, and defaulting the other way makes it possible.
        config.adapter ||= :test if Rails.env.test?

        # And the preview adapter in development, which is the floor rather
        # than a preference.
        #
        # Without it a fresh application has no adapter, so asking for one
        # raises ConfigurationError -- and sparrow_auth swallows every
        # SparrowMail::Error when it sends a sign-in code, deliberately, so
        # that a provider having a bad day cannot become a way to learn which
        # addresses have accounts. Both of those are right on their own.
        # Together they meant a developer typed their address into a brand new
        # application, read "check your email", and waited for a message that
        # was never sent and never would be.
        #
        # So with nothing configured, mail is written to tmp/sparrowkit-mail
        # and the control panel shows it. What this does NOT do is claim mail
        # is being delivered: the panel goes on reporting no provider, in
        # amber, with the folder named. See Console::Report::FALLBACK_ADAPTER.
        #
        # `||=`, so an application that has configured anything at all -- even
        # deliberately configuring nothing but a stream -- still wins.
        config.adapter ||= :preview if Rails.env.development?

        # And a sender, on the same terms and for the same reason.
        #
        # The preview adapter gave mail somewhere to go; it did not give it an
        # address to come FROM, and a message with no sender raises. So a fresh
        # application still could not send anything -- the failure had simply
        # moved one line down, from "no adapter configured" to "no from address",
        # and the second is the one a developer meets while trying to sign in for
        # the first time.
        #
        # Found by installing into a real application and pressing the button,
        # which is the only way this class of gap is ever found: every suite in
        # this repository configures a sender in its setup, so none of them could
        # see it.
        #
        # The address says what it is. `.invalid` is reserved by RFC 2606 and
        # can never be registered, so nothing can reply to it and no bounce
        # reaches anybody -- and the control panel goes on reporting that no
        # sender is set, because none is.
        config.default_from ||= SparrowMail::FALLBACK_FROM if Rails.env.development?
      end
    end
  end
end
