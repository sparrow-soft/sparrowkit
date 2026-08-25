# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "spec_helper"
require_relative "dummy/config/environment"
require "rspec/rails"

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

  config.infer_spec_type_from_file_location!

  # Credentials written by one example must not decide another's sender name.
  # See ConsoleCredentials#restore_baseline! — it does nothing at all for the
  # examples that never wrote one.
  config.after do
    ConsoleCredentials.restore_baseline!
  end
end
