# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_view/railtie"

# ActiveRecord and a PostgreSQL database, neither of which the console uses.
#
# Worth knowing why, because two lighter versions of this file were tried and
# both failed the same way. Every panel reads and writes Rails encrypted
# credentials and queries nothing, so first there was no ActiveRecord at all,
# and then there was ActiveRecord on a SQLite file. Both 500 on every page with
# `cannot load such file -- pg`.
#
# The reason is not the console. sparrow_auth mounts Rodauth, whose middleware
# sits in front of the whole application, and its configuration says
# `Sequel.postgres(extensions: :activerecord_connection)` outright -- ADR 0001,
# PostgreSQL everywhere. That runs before any console page does.
#
# A connection is required. A schema is not: nothing here is ever migrated, and
# the database stays empty. See the note further down.

Bundler.require(*Rails.groups)

require "sparrow_ui"
require "sparrow_auth"
require "sparrow_mail"
require "sparrow_pay"

module Preview
  class Application < Rails::Application
    config.load_defaults 8.0
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.secret_key_base = "preview" * 16

    # The console's loopback guard reads the socket peer, so requests have to
    # arrive from this machine -- which they do, since the server binds to
    # 127.0.0.1. Nothing here is reachable from anywhere else.
    config.hosts.clear

    config.session_store :cookie_store, key: "_sparrowkit_preview"
    config.middleware.use ActionDispatch::Cookies
    config.middleware.use config.session_store, config.session_options

    config.action_mailer.delivery_method = :sparrow_mail
    config.action_mailer.default_url_options = {host: "example.test"}

    # No migrations, deliberately, and the database stays empty.
    #
    # What Rodauth's middleware wants is a connection; it reads a table only
    # once a request reaches an auth route, and no console page is one. So an
    # empty database is the whole of the setup, and `bin/console` creating it is
    # the only step there is.
    #
    # The consequence, stated plainly: this host cannot exercise signing in,
    # sending or billing. A page that tried would fail loudly on a missing
    # table, which is the right way for that boundary to announce itself. Use a
    # gem's own dummy for anything past the console.

    # Its own credentials, under tmp/, generated on first boot.
    #
    # Separate from any real application's, because this is a scratch host and
    # the panels write to it for real: a preview that shared credentials with
    # something that mattered would be a preview that could break it.
    config.credentials.content_path = File.expand_path("../tmp/credentials.yml.enc", __dir__)
    config.credentials.key_path = File.expand_path("../tmp/master.key", __dir__)

    # Without this every panel renders its "this page cannot save anything yet"
    # state, which is correct and useless: the forms are the thing being looked
    # at. Generated rather than committed -- a master key in a repository is a
    # habit worth not forming, even for a throwaway.
    initializer "preview.credentials" do |app|
      key = Pathname(app.config.credentials.key_path)
      next if key.exist?

      key.dirname.mkpath
      key.write(ActiveSupport::EncryptedFile.generate_key)
      app.credentials.write({"secret_key_base" => "preview" * 16}.to_yaml)
    end
  end
end
