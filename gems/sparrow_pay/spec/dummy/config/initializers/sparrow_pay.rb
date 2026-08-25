# frozen_string_literal: true

Pay.setup do |config|
  # No routes. Pay mounts its webhook endpoints by default, and a host decides
  # where those live — Step 4 covers the engine's side of them.
  config.automount_routes = false
end

SparrowPay.configure do |config|
  config.default_processor = :fake_processor
end
