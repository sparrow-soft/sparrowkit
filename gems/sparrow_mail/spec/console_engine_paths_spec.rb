# frozen_string_literal: true

require "rails_helper"

# The panel lives under console/app, not app/, to match sparrow_auth and
# sparrow_pay -- where the location is load-bearing, because their main
# engines eager load everything under app/ on a production boot and the
# panel's controller references constants that only exist where sparrow_ui
# does. sparrow_mail's main integration is a Railtie with no paths, so app/
# here was only ever the console engine's; one layout across the three gems
# means nobody has to remember which gem is the exception.
RSpec.describe SparrowMail::ConsoleEngine do
  it "claims the panel's controllers from console/app" do
    expect(described_class.paths["app/controllers"].existent)
      .to include(a_string_ending_with("console/app/controllers"))
  end

  it "claims the panel's views from console/app" do
    expect(described_class.paths["app/views"].existent)
      .to include(a_string_ending_with("console/app/views"))
  end

  it "keeps no app/ directory at the gem root at all" do
    expect(SparrowMail::ConsoleEngine.root.join("app")).not_to exist
  end
end
