# frozen_string_literal: true

# Drawn into SparrowPay::ConsoleEngine, which sparrow_ui mounts at
# /sparrowkit/pay. See lib/sparrow_pay/console_engine.rb for why this file is
# not config/routes.rb.
SparrowPay::ConsoleEngine.routes.draw do
  root to: "console/sparrowkit#show"
  patch "/", to: "console/sparrowkit#update", as: :sparrowkit
end
