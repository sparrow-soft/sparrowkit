# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)
require "sparrow_ui"

# Required explicitly, and only here. This suite's .rspec preloads spec_helper,
# which requires sparrow_ui before any of this file runs -- so lib/sparrow_ui.rb
# saw no ::Rails::Engine, skipped the engine, and the require above is a no-op
# by the time Rails exists. That is the one case sparrow_mail's railtie guard
# names out loud: load the gem before Rails and you require the Rails half
# yourself, once Rails is up. A real host is the other way round, because
# Bundler.require runs after Rails is loaded.
#
# It has to happen before initialize! below, or the engine's initializers never
# run and the sk_* helpers are absent from ActionView.
require "sparrow_ui/engine"

# sparrow_mail's Rails half, for the same reason and with the same wrinkle: the
# gem was already loaded above without Rails present, so its railtie -- which
# carries the panel registration -- was skipped. Requiring it here, before the
# Application class below is defined, is what puts the Mail panel on the hub.
require "sparrow_mail"
require "sparrow_mail/railtie"

# A bare host. No ActiveRecord: this engine renders markup and nothing else, and
# a dummy that booted a database would hide a dependency on one.
module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy" * 16
    config.logger = ActiveSupport::Logger.new(IO::NULL)

    # A panel's whole job is writing to Rails encrypted credentials, so this
    # host needs some or every panel renders its "cannot save anything yet"
    # state and bin/console demonstrates nothing.
    #
    # Generated on first boot into an ignored tmp directory rather than
    # committed: a master key in a repository is a habit worth not forming,
    # even for a throwaway host with nothing in it.
    config.credentials.content_path = File.expand_path("../tmp/credentials.yml.enc", __dir__)
    config.credentials.key_path = File.expand_path("../tmp/master.key", __dir__)

    initializer "dummy.credentials" do |app|
      key = Pathname(app.config.credentials.key_path)
      next if key.exist?

      key.dirname.mkpath
      key.write(ActiveSupport::EncryptedFile.generate_key)
      app.credentials.write({"secret_key_base" => "dummy" * 16}.to_yaml)
    end
  end
end
