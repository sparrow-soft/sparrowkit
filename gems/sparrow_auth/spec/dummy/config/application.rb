# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"

Bundler.require(*Rails.groups)
require "sparrow_auth"

# A bare host application, which is the point. If the engine needs anything
# beyond mounting to work, it has to ship that itself rather than rely on a
# generator having been run or a host having been told.
module Dummy
  class Application < Rails::Application
    config.load_defaults 8.0
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "dummy" * 16

    config.session_store :cookie_store, key: "_dummy_session"
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use config.session_store, config.session_options

    config.action_mailer.delivery_method = :sparrow_mail
    config.action_mailer.default_url_options = {host: "example.test"}
    config.logger = ActiveSupport::Logger.new(IO::NULL)

    # The console panel's whole job is writing to Rails encrypted credentials,
    # so the specs need real ones -- a stubbed Settings would not exercise the
    # rule that a blank secret is dropped rather than written, which is the part
    # most worth proving. They are generated per example into an ignored tmp
    # directory: a master key in the repository is a habit worth not forming,
    # even for a throwaway host. See spec/support/console_credentials.rb.
    config.credentials.content_path = File.expand_path("../tmp/credentials.yml.enc", __dir__)
    config.credentials.key_path = File.expand_path("../tmp/master.key", __dir__)

    # Generated on first boot as well as per example, so the panel is usable by
    # hand and not only by the suite. Without this the page renders its "cannot
    # save anything yet" state to anybody who boots this host to look at it --
    # correct, and a poor demonstration of a form whose whole job is saving.
    initializer "dummy.credentials" do |app|
      key = Pathname(app.config.credentials.key_path)
      next if key.exist?

      key.dirname.mkpath
      key.write(ActiveSupport::EncryptedFile.generate_key)
      app.credentials.write({"secret_key_base" => "dummy" * 16}.to_yaml)
    end
  end
end
