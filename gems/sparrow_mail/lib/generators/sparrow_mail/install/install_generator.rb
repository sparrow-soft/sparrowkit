# frozen_string_literal: true

require "rails/generators"
require "generators/sparrowkit/install_steps"

module SparrowMail
  module Generators
    # Wires sparrow_mail into a host application.
    #
    #   bin/rails sparrow_mail:install
    #
    # WRITES NO SETTINGS AND NO INITIALIZER. There was one, and it configured
    # the provider, the sender and sandbox mode -- the same three things the
    # control panel writes to encrypted credentials. Because config/initializers
    # is evaluated after credentials are read, it silently won: a developer who
    # ran the old generator and then chose Postmark in the panel had their
    # provider reset to the test adapter on the next boot, and every message
    # went nowhere with no error at all.
    #
    # So this installer only does what a gem genuinely cannot do for itself:
    # point ActionMailer at the delivery method, and mount the control panel.
    # Everything else is a form.
    class InstallGenerator < Rails::Generators::Base
      include Sparrowkit::InstallSteps

      desc "Points ActionMailer at sparrow_mail and mounts the SparrowKit control panel."

      # ActionMailer has to be told which delivery method to use, and no gem can
      # decide that for a host -- an application may deliberately send through
      # something else in some environments.
      #
      # config/application.rb rather than per-environment files, because the
      # railtie already selects the test adapter in the test environment, so one
      # line covers every environment without a suite being able to reach a real
      # provider.
      DELIVERY_METHOD = "config.action_mailer.delivery_method = :sparrow_mail"

      def point_action_mailer_at_us
        application_path = File.join(destination_root, "config", "application.rb")

        if File.exist?(application_path) && File.read(application_path).include?(DELIVERY_METHOD)
          say_status :unchanged, "config/application.rb already sets the delivery method", :yellow
          return
        end

        application "\n    # Mail leaves through sparrow_mail. Which provider, and its API key,\n" \
                    "    # are set at http://localhost:3000/sparrowkit/mail\n" \
                    "    #{DELIVERY_METHOD}\n"
      end

      def mount_console
        ensure_console_mount
      end

      # No migrations: this gem owns no tables.

      def report
        report_console "sparrow_mail is installed. Choose a provider and give it an API key."
      end
    end
  end
end
