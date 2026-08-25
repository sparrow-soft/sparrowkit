# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rspec/rails"

# A real Postgres, a real Rails stack, a real engine mount. An auth engine
# tested against anything less is testing something other than what it ships.
#
# The engine's own migrations are run against the test database, which also
# means every constraint in them is exercised by the suite rather than trusted.
ActiveRecord::Migration.verbose = false
ActiveRecord::MigrationContext.new(
  SparrowAuth::Engine.root.join("db", "migrate").to_s
).migrate

# The dummy application's own migrations, run separately because that is how a
# host application actually works: its tables are its own, and the engine's
# tenancy helpers have to hold against a model the engine never saw.
ActiveRecord::MigrationContext.new(
  File.expand_path("dummy/db/migrate", __dir__)
).migrate

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

RSpec.configure do |config|
  # The console answers only to loopback names -- see
  # SparrowUi::Console::LoopbackGuard#loopback_name?, which is what stops a
  # tunnelled development machine publishing a page that writes credentials.
  # Rails' default test host is www.example.com, which is precisely the shape a
  # tunnel presents, so a console spec that did not set this would be asserting
  # against the 404.
  config.before(type: :request) do |example|
    host! "localhost" if example.metadata[:file_path].include?("/console/")
  end

  config.use_transactional_fixtures = true

  # travel_to and friends, for the specs about expiry.
  config.include ActiveSupport::Testing::TimeHelpers
  config.infer_spec_type_from_file_location!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Credentials written by one example must not decide another's passkey domain.
  # See ConsoleCredentials#restore_baseline! — cheap, because it does nothing at
  # all for the examples that never wrote one.
  config.after do
    ConsoleCredentials.restore_baseline!
  end

  config.before do
    SparrowAuth.reset!

    # Passwords are OFF by default in the engine, and on here.
    #
    # Most of this suite uses a password as the cheapest way to get an account
    # into a signed-in state before testing something else entirely, so turning
    # them on keeps those specs about their own subject. It is set explicitly,
    # here, so that dependence is visible rather than assumed — and
    # spec/requests/password_flag_spec.rb runs the flag in both positions,
    # because a flag proven in one position is not proven.
    SparrowAuth.config.passwords_enabled = true

    # reset! also clears the providers the dummy app configured at boot. The
    # feature is already enabled on the Rodauth class by then — that happens
    # once, at load — but anything reading the list at runtime needs it back.
    SparrowAuth.config.social_providers = {developer: []}

    # Same reason: reset! clears the invitation policy the dummy app set at
    # boot, and SparrowKit refuses every organization invitation without one.
    SparrowAuth.config.authorize_invitation = lambda do |inviter:, organization:, role:|
      inviter.membership_in(organization).present?
    end

    # Tenancy state, cleared between examples. Rails resets CurrentAttributes
    # around requests and jobs, but a model spec that sets one leaves it set,
    # and an organization leaking from one example into the next is precisely
    # the bug these helpers exist to prevent — it would make a scoped query
    # pass while proving nothing.
    SparrowAuth::Current.reset

    SparrowMail.reset!

    # Required by name, not left to the registry.
    #
    # Adapters are registered lazily: the registry requires the file the first
    # time something fetches one, so SparrowMail::Adapters::Test does not exist
    # as a constant until a message has actually been sent. Specs that reach for
    # it directly -- to inject a delivery failure -- therefore passed or raised
    # NameError depending on whether an earlier example in the same process had
    # sent anything, which is to say depending on the seed.
    require "sparrow_mail/adapters/test"

    SparrowMail.configure do |c|
      c.adapter = :test
      c.default_from = "SparrowAuth Dummy <no-reply@example.test>"
    end
  end
end
