# frozen_string_literal: true

require "spec_helper"

# What a panel knows about itself, as the header and the hub ask it.
#
# The two questions here are presentation, not module behaviour: what to call
# this panel where there is only room for a word, and whether the page being
# rendered is one of its own. Both used to be worked out in ERB, where a rule
# cannot be tested and an off-by-one slash is invisible until somebody notices
# the wrong link is lit.
RSpec.describe SparrowUi::Console::Panel do
  # Mountable, because register refuses anything that is not: config/routes.rb
  # mounts every registered panel, and a fake that cannot answer a request only
  # fails later, from the route set, on whichever seed happens to redraw routes
  # while it is registered.
  let(:fake_engine) { ->(_env) { [200, {"content-type" => "text/plain"}, ["a panel"]] } }

  def panel(key:, name:, short_name: nil)
    described_class.new(key: key, name: name, short_name: short_name, engine: fake_engine)
  end

  describe "#short_name" do
    it "is what the module asked to be called in a nav" do
      expect(panel(key: :auth, name: "Authentication", short_name: "Auth").short_name).to eq("Auth")
    end

    # A module that says nothing gets a link rather than a blank one.
    it "falls back to the full name" do
      expect(panel(key: :mail, name: "Mail").short_name).to eq("Mail")
    end
  end

  describe "#current?" do
    let(:mail) { panel(key: :mail, name: "Mail") }

    it "is the panel's own page" do
      expect(mail.current?("/sparrowkit/mail", "/sparrowkit")).to be(true)
    end

    # A panel owns everything under its mount, so a page it may add later is
    # still the same panel and the nav should still say so.
    it "is a page nested inside the panel" do
      expect(mail.current?("/sparrowkit/mail/domains", "/sparrowkit")).to be(true)
    end

    it "is not the hub" do
      expect(mail.current?("/sparrowkit", "/sparrowkit")).to be(false)
    end

    it "is not another panel" do
      expect(mail.current?("/sparrowkit/auth", "/sparrowkit")).to be(false)
    end

    # The reason the nested test above is a `start_with?` on "#{href}/" and not
    # on href. Without the slash every one of these lights up the Mail link.
    it "is not a sibling whose path merely begins the same way" do
      expect(mail.current?("/sparrowkit/mailer", "/sparrowkit")).to be(false)
      expect(mail.current?("/sparrowkit/mailgun/setup", "/sparrowkit")).to be(false)
    end

    # Mounted at the host's root the prefix is empty, and the paths are still
    # absolute and still right.
    it "works with no prefix at all" do
      expect(mail.current?("/mail", "")).to be(true)
      expect(mail.current?("/mailer", "")).to be(false)
    end
  end
end
