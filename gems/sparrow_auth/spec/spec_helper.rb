# frozen_string_literal: true

RSpec.configure do |config|
  config.expect_with(:rspec) { |c| c.syntax = :expect }
  config.disable_monkey_patching!
  config.shared_context_metadata_behavior = :apply_to_host_groups
end
