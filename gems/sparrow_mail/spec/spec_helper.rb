# frozen_string_literal: true

require "sparrow_mail"
require "webmock/rspec"
require "sparrow_mail/conformance"
require "sparrow_mail/conformance/http_driver"

# Adapters are registered lazily so that installing the gem does not load the
# AWS SDK. The suite loads them all eagerly, because it names their constants.
SparrowMail::BUILT_IN_ADAPTERS.each_value { |(path, _constant)| require path }

Dir[File.expand_path("support/**/*.rb", __dir__)].sort.each { |f| require f }

WebMock.disable_net_connect!(allow_localhost: true)

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  config.before do
    SparrowMail.reset!
    SparrowMail::Adapters::Test.reset!
  end
end
