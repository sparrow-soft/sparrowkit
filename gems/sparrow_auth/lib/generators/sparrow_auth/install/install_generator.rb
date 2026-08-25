# frozen_string_literal: true

require "rails/generators"
require "generators/sparrowkit/install_steps"

module SparrowAuth
  module Generators
    # Writes the initializer, mounts the engine, and installs the migrations.
    #
    #   rails generate sparrow_auth:install
    #
    # The initializer is the point of this. Everything the engine can do is
    # configurable, but only three of those settings are decisions a host must
    # actually make — and reading a table of twenty-six to find them is how the
    # three get missed. So the file is written grouped by decision, with the
    # ones that matter at the top, each with what happens if it is left alone.
    #
    # A generated file is also the only documentation that cannot go stale
    # against the code, because it ships beside it.
    class InstallGenerator < Rails::Generators::Base
      include Sparrowkit::InstallSteps

      source_root File.expand_path("templates", __dir__)

      class_option :mount_at,
        type: :string,
        default: "/auth",
        desc: "Where to mount the engine. Rodauth's path_prefix is set to match."

      # The code-only options: callbacks, declared roles, provider hashes. None of
      # them could be a value in a settings file, which is why this file still
      # exists after the settings moved to the control panel.
      #
      # An existing initializer is the developer's and is never touched. Thor's
      # answer to a collision is a prompt, and a prompt read from a closed
      # stdin -- an agent, CI, anything piped -- answers itself YES: re-running
      # the app template replaced a host's customized initializer (its
      # after_first_signin hook, its mail_from) with the stock copy, silently.
      def create_initializer
        if File.exist?(File.join(destination_root, "config/initializers/sparrow_auth.rb"))
          say_status :unchanged,
            "config/initializers/sparrow_auth.rb is already yours; " \
            "the stock copy is at #{File.expand_path("templates/sparrow_auth.rb.tt", __dir__)}",
            :yellow
          return
        end

        template "sparrow_auth.rb.tt", "config/initializers/sparrow_auth.rb"
      end

      def mount_engine
        ensure_route %(mount SparrowAuth::Engine => "#{mount_at}"),
          matching: /mount\s+SparrowAuth::Engine/
      end

      def mount_console
        ensure_console_mount
      end

      def install_tables
        install_and_run_migrations SparrowAuth::Engine
      end

      def report
        report_console(
          "sparrow_auth is installed at #{mount_at}.",
          "",
          "SET YOUR APPLICATION'S ADDRESS BEFORE YOU DEPLOY, on the SparrowKit",
          "home page at /sparrowkit. Its domain is what passkeys are permanently",
          "bound to, and it is the one setting here that a later change cannot",
          "undo — a passkey cannot be moved to a different domain, so getting it",
          "wrong is undone by every user enrolling again.",
          "",
          "Only set webauthn_rp_id if passkeys need a DIFFERENT domain from the",
          "address — a site at www.example.com usually wants passkeys on",
          "example.com, so they keep working on every subdomain.",
          "",
          "The callbacks that are code — how an account gets",
          "provisioned, who may administer an organization — are in",
          "config/initializers/sparrow_auth.rb."
        )
      end

      private

      def mount_at
        options[:mount_at]
      end
    end
  end
end
