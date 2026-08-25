# frozen_string_literal: true

require "rails/generators"
require "generators/sparrowkit/install_steps"

module SparrowPay
  module Generators
    # Wires sparrow_pay into a host application.
    #
    #   bin/rails sparrow_pay:install
    #
    # NO INITIALIZER, and none is needed. Every setting this gem has that a host
    # would actually change -- which processor, who may bill, where checkout
    # returns to -- is written by the control panel to encrypted credentials and
    # read by the engine at boot. The one that is not, `plan_cache_for`, has a
    # sensible default measured in hours and is documented in the README.
    #
    # A generated settings file would only be a second place for those values to
    # live, and since config/initializers is evaluated after credentials are
    # read, the second place would silently win.
    class InstallGenerator < Rails::Generators::Base
      include Sparrowkit::InstallSteps

      desc "Mounts the billing engine, installs its tables, and mounts the SparrowKit control panel."

      class_option :mount_at,
        type: :string,
        default: "/billing",
        desc: "Where to mount the billing pages."

      def mount_engine
        ensure_route %(mount SparrowPay::Engine => "#{options[:mount_at]}"),
          matching: /mount\s+SparrowPay::Engine/
      end

      def mount_console
        ensure_console_mount
      end

      # PAY's tables, not ours.
      #
      # This gem has none of its own -- it holds your processor's credentials
      # and wires Pay up. The customers, subscriptions, charges and payment
      # methods are Pay's, from Pay's own migrations.
      #
      # Running them here is the whole point of this step. It used to install
      # only sparrow_pay's own migration and stop, so `pay_customers` never
      # existed and the first call to `organization.payment_processor` raised
      # `Could not find table 'pay_customers'` -- on a completed, successful
      # install, with the panel reporting the module ready.
      def install_tables
        install_and_run_migrations ::Pay::Engine
      end

      def report
        report_console(
          "sparrow_pay is installed at #{options[:mount_at]}.",
          "",
          "Pay's tables are in. What it cannot decide for you is which processor",
          "takes the money, and its API keys — both are on the control panel.",
          "",
          "There are no billing pages: what a customer reads about their plan is",
          "the most application-specific screen there is. Build it on Pay's own",
          "API, from organization.payment_processor."
        )
      end
    end
  end
end
