# frozen_string_literal: true

require "rails_helper"

# Two engines, one gem directory, and the paths that must not be shared. The
# fuller account is in sparrow_auth's spec of the same name; the routes and
# rake-task halves are asserted there and the layout is identical here.
#
# What this file pins is the production half. The panel's controller includes
# SparrowPay::ConsoleEngine's URL helpers in its class body, and that constant
# only exists where sparrow_ui does -- which production is not. The billing
# engine eager loads everything under the gem's app/ on a production boot, so
# the panel living there booted every production host straight into
# `uninitialized constant SparrowPay::ConsoleEngine`. It lives under
# console/app, claimed by the console engine alone.
RSpec.describe SparrowPay::ConsoleEngine do
  it "claims the panel's controllers from console/app" do
    expect(described_class.paths["app/controllers"].existent)
      .to include(a_string_ending_with("console/app/controllers"))
  end

  it "claims the panel's views from console/app" do
    expect(described_class.paths["app/views"].existent)
      .to include(a_string_ending_with("console/app/views"))
  end

  it "leaves nothing console-shaped under the eager-loaded app/" do
    expect(Dir[SparrowPay::Engine.root.join("app/**/*console*").to_s]).to be_empty
  end
end
