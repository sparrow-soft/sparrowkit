# frozen_string_literal: true

require_relative "boot"

require "rails"
require "action_controller/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)

# Both halves, required explicitly and in this order, and neither line is
# decoration.
#
# This suite's .rspec preloads spec_helper, which requires sparrow_mail before
# any of this file runs -- so lib/sparrow_mail.rb saw no ::Rails::Railtie and
# skipped the Rails half, which is where the console panel is registered. That
# is the exact case the guard at the bottom of lib/sparrow_mail.rb names out
# loud: load the gem before Rails, and you require the Rails half yourself once
# Rails is up. A real host is the other way round.
#
# sparrow_ui has to be loaded before the Application class below, not merely
# before initialize!: the registration hook fires when that class is defined,
# and it asks whether there is a console to register with.
require "sparrow_mail"
require "sparrow_mail/railtie"
require "sparrow_ui"
require "sparrow_ui/engine"

# A bare host. No ActiveRecord: the panel reads and writes Rails credentials and
# nothing else, and a dummy that booted a database would hide a dependency on
# one.
module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy" * 16
    config.logger = ActiveSupport::Logger.new(IO::NULL)

    # The panel's whole job is writing to Rails encrypted credentials, so the
    # specs need real ones -- a stubbed Settings would not exercise the rule
    # that a blank secret is dropped rather than written, which is the part
    # most worth proving. They are generated per example into an ignored tmp
    # directory: a master key in the repository is a habit worth not forming,
    # even for a throwaway host. See spec/support/console_credentials.rb.
    config.credentials.content_path = File.expand_path("../tmp/credentials.yml.enc", __dir__)
    config.credentials.key_path = File.expand_path("../tmp/master.key", __dir__)
  end
end
