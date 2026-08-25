# frozen_string_literal: true

ENV["RAILS_ENV"] = "test"

require_relative "dummy/config/environment"
require "rspec/rails"

# A real Postgres and a real Rails stack, with Pay's own tables. A billing layer
# tested against stubs is testing its own idea of Pay rather than Pay.
ActiveRecord::Migration.verbose = false

# Three sets, in dependency order. Pay's tables reference nothing of ours, but
# ours reference sparrow_auth's organizations, so the order is not incidental.
[
  Pay::Engine.root.join("db", "migrate").to_s,
  SparrowAuth::Engine.root.join("db", "migrate").to_s,
  SparrowPay::Engine.root.join("db", "migrate").to_s
].each do |path|
  ActiveRecord::MigrationContext.new(path).migrate
end

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
  config.include ActiveSupport::Testing::TimeHelpers
  config.infer_spec_type_from_file_location!
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random

  config.before do
    SparrowPay.reset!
    SparrowAuth.reset!

    # Plans are cached, so one example's lookup would otherwise answer the
    # next one's.
    Rails.cache.clear

    # Passwords are OFF in sparrow_auth by default, and these specs use one as
    # the cheapest way to get a signed-in session before testing something
    # else entirely. Set here rather than in an initializer because
    # SparrowAuth.reset! above wipes it. sparrow_auth's own suite does the same,
    # for the same reason.
    SparrowAuth.config.passwords_enabled = true
    SparrowAuth.config.mail_from = "Billing Demo <no-reply@example.test>"

    SparrowPay.configure do |config|
      config.default_processor = :fake_processor
      config.allow_fake_processor = true
    end
  end
end
