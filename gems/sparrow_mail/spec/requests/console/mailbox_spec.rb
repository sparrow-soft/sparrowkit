# frozen_string_literal: true

require "rails_helper"
require "tmpdir"

# The mailbox on the panel: what a fresh application's mail does while nobody
# has chosen a provider.
#
# It exists because of a hole nothing else covered. sparrow_auth swallows every
# SparrowMail::Error on the sign-in path, deliberately, so that a provider
# having a bad day cannot become a way to learn which addresses have accounts.
# With no adapter at all, that swallowed the whole of first run: somebody typed
# their address into a brand new application, read "check your email", and
# waited for a message nothing had sent.
#
# So mail is written to a folder instead, and this is where it can be read.
PANEL = "/sparrowkit/mail"
MAILBOX = "/sparrowkit/mail/mailbox"

RSpec.describe "the mailbox on the mail panel", type: :request do
  around do |example|
    Dir.mktmpdir("mailbox-spec") do |dir|
      SparrowMail::Adapters::Preview.directory = File.join(dir, "mail")
      begin
        example.run
      ensure
        SparrowMail::Adapters::Preview.directory = nil
      end
    end
  end

  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
    Rails.cache.clear
  end

  # What the railtie does in development when nothing is configured.
  def no_provider_yet
    SparrowMail.configure do |config|
      config.adapter = :preview
      config.default_from = "SparrowKit <kit@example.com>"
    end
  end

  def send_one(subject: "Your sign-in code", to: "you@example.test", body: "Your code is 483927")
    SparrowMail.deliver!(
      Mail.new.tap do |mail|
        mail.from = "SparrowKit <kit@example.com>"
        mail.to = to
        mail.subject = subject
        mail.body = body
      end
    )
  end

  describe "while no provider is configured" do
    before { no_provider_yet }

    it "says nothing has been delivered, and where the mail went instead" do
      get PANEL

      expect(response.body).to include("Mail this application sent")
      expect(response.body).to include(SparrowMail::Adapters::Preview::DIRECTORY)
    end

    it "explains the empty state rather than showing an empty box" do
      get PANEL

      expect(response.body).to match(/Nothing yet/i)
    end

    it "shows a message that was sent, with the code in it" do
      send_one

      get PANEL

      expect(response.body).to include("Your sign-in code")
      expect(response.body).to include("you@example.test")
      expect(response.body).to include("483927")
    end

    it "empties it when asked" do
      send_one
      expect(SparrowMail::Adapters::Preview.count).to eq(1)

      delete MAILBOX

      expect(SparrowMail::Adapters::Preview.count).to eq(0)
      expect(flash[:notice]).to match(/empty/i)
    end
  end

  describe "the badge, which must not go green because of this" do
    before { no_provider_yet }

    # The whole risk of selecting an adapter by default: the panel decides it is
    # configured, turns green, and stops telling anybody that nobody is
    # receiving their mail.
    it "still reports no provider" do
      status = SparrowMail::Console::Report.new.status

      expect(status[:state]).to eq(:unconfigured)
      expect(status[:detail]).to include(SparrowMail::Adapters::Preview::DIRECTORY)
    end

    # On the panel itself rather than only on the hub badge. The findings list
    # is a hub thing; somebody standing on this page filling in a provider needs
    # to be told, here, that nothing is currently reaching anybody.
    it "says on the page that nothing is being delivered" do
      get PANEL

      expect(response.body).to match(/nothing is being delivered to anybody/i)
    end

    # Phase 4 stopped the :test adapter being offered because this button could
    # report success having reached no network. Defaulting to :preview reopened
    # exactly that hole from the other side.
    it "refuses the test send, which is the one control that must not lie" do
      post "#{PANEL}/test", params: {recipient: "dev@example.org"}

      expect(flash[:alert]).to match(/no provider to test yet/i)
      expect(SparrowMail::Adapters::Preview.count).to eq(0)
    end
  end

  describe "once a provider is configured" do
    before do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.default_from = "SparrowKit <kit@example.com>"
      end
    end

    # A list of whatever happened to be in tmp/ before they configured a
    # provider is worse than no list: the provider's own dashboard is the
    # truthful place to look, and two answers is how somebody comes to trust
    # the wrong one.
    it "shows no mailbox at all, even with files still in the folder" do
      SparrowMail::Adapters::Preview.new.deliver!(
        Mail.new.tap do |mail|
          mail.from = "old@example.com"
          mail.to = "someone@example.org"
          mail.subject = "From before"
          mail.body = "Left over"
        end
      )

      get PANEL

      expect(response.body).not_to include("Mail this application sent")
      expect(response.body).not_to include("From before")
    end
  end

  # The gap the preview adapter left, found by installing into a real
  # application and pressing the button rather than by reading anything.
  #
  # The adapter gave mail somewhere to go. It did not give it an address to come
  # FROM, and a message with no sender raises -- so a fresh application still
  # could not send, and the failure had simply moved from "no adapter" to "no
  # from address". Every suite in this repository sets a sender in its own
  # setup, which is why none of them could see it.
  describe "the sender a fresh application gets" do
    it "is a placeholder that can never receive a reply" do
      expect(SparrowMail::FALLBACK_FROM).to include("localhost.invalid")
    end

    # Treating the placeholder as a configured sender would swap one silent
    # failure for a page saying everything is fine while every message goes out
    # from an address at localhost.invalid.
    it "is still reported as no sender at all" do
      SparrowMail.configure do |config|
        config.adapter = :preview
        config.default_from = SparrowMail::FALLBACK_FROM
      end

      finding = SparrowMail::Console::Report.new.findings
        .find { |f| f[:title] == "There is no default sender" }

      expect(finding).to be_present
      expect(finding[:detail]).to match(/placeholder/i)
    end

    it "stops being reported once a real one is set" do
      SparrowMail.configure do |config|
        config.adapter = :preview
        config.default_from = "Acme <hello@acme.test>"
      end

      titles = SparrowMail::Console::Report.new.findings.map { |f| f[:title] }

      expect(titles).not_to include("There is no default sender")
    end
  end
end
