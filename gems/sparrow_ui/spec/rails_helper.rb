# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"

require "spec_helper"
require_relative "dummy/config/environment"
require "rspec/rails"

Dir[File.join(__dir__, "support", "**", "*.rb")].sort.each { |file| require file }

RSpec.configure do |config|
  # Every request in this suite is a request to the console, and the console
  # answers only to loopback names -- see LoopbackGuard#loopback_name?. Rails'
  # default test host is www.example.com, which is exactly the shape of host a
  # tunnel presents, so without this the whole suite would be testing the 404.
  config.before(type: :request) { host! "localhost" }

  config.infer_spec_type_from_file_location!
end
