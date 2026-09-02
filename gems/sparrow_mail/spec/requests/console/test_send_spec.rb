# frozen_string_literal: true

require "rails_helper"

# The panel's test send: one address, one button, one honest answer to "are
# these credentials actually right?" -- which is otherwise unanswerable
# without writing a mailer and triggering it.
#
# It sends through SparrowMail.deliver, the same path the application's own
# mail takes, because a test that exercises a different path answers a
# different question.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
TEST_SEND = "/sparrowkit/mail/test"

RSpec.describe "sending a test email from the panel", type: :request do
  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
    # The cooldown lives in Rails.cache, which outlives an example. Without
    # this, whichever example sends first silences every later one.
    Rails.cache.clear
  end

  def configure_mail
    SparrowMail.configure do |config|
      config.adapter = :test
      config.default_from = "SparrowKit <kit@example.com>"
    end
  end

  # Two providers: the transactional stream on the default adapter and a
  # broadcast stream of its own. Both :test, which records rather than
  # sends, and which has no reputation for the separation check to weigh.
  def configure_two
    SparrowMail.configure do |config|
      config.adapter = :test
      config.default_from = "SparrowKit <kit@example.com>"
      config.stream :broadcast, adapter: :test
    end
  end

  def streams_delivered
    SparrowMail.deliveries.map(&:stream)
  end

  it "sends through the configured adapter, from the configured sender" do
    configure_mail

    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(SparrowMail.deliveries.size).to eq(1)
    envelope = SparrowMail.deliveries.last
    expect(envelope.to.map(&:email)).to include("dev@example.org")
    expect(envelope.from.email).to eq("kit@example.com")
    expect(flash[:notice]).to match(/test/i)
  end

  it "sends on the transactional stream, never the broadcast one" do
    # Auth mail rides the transactional reputation (rule 7), and so does the
    # message that tests it.
    configure_mail

    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(SparrowMail.deliveries.last.stream).to eq(SparrowMail::Envelope::DEFAULT_STREAM)
  end

  it "refuses a blank recipient rather than guessing one" do
    configure_mail

    post TEST_SEND, params: {recipient: "  "}

    expect(SparrowMail.deliveries).to be_empty
    expect(flash[:alert]).to match(/address/i)
  end

  it "says a provider must be chosen first, instead of crashing without one" do
    # A fresh install has no adapter. ConfigurationError is a caller bug in
    # application code; on this page the caller is the developer mid-setup,
    # and the answer is the next step, not a stack trace.
    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(response).to have_http_status(:found)
    expect(flash[:alert]).to match(/provider/i)
  end

  it "says a sender must be named first, when only that is missing" do
    SparrowMail.configure { |config| config.adapter = :test }

    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(SparrowMail.deliveries).to be_empty
    expect(flash[:alert]).to match(/sender/i)
  end

  it "reports a refused send in the taxonomy's words, not a backtrace" do
    configure_mail
    error = SparrowMail::AuthenticationError.new("provider said 401")
    allow(SparrowMail).to receive(:deliver).and_return(
      SparrowMail::Result.failed(error, recipients: ["dev@example.org"])
    )

    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(flash[:alert]).to match(/credentials/i)
    expect(flash[:alert]).to include("provider said 401")
  end

  it "holds a second send back inside the cooldown, so a stuck finger cannot spend reputation" do
    configure_mail

    post TEST_SEND, params: {recipient: "dev@example.org"}
    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(SparrowMail.deliveries.size).to eq(1)
    expect(flash[:alert]).to match(/moment/i)
  end

  # Two providers are two sets of credentials and two reputations. A test
  # that proved one of them leaves the newsletter path unproven until the
  # first newsletter, so with two configured the panel sends one of each
  # unless told otherwise, and reports each on its own.
  describe "with a provider for each kind of mail" do
    before { configure_two }

    it "sends one message on each stream when nothing narrower is asked" do
      post TEST_SEND, params: {recipient: "dev@example.org"}

      expect(streams_delivered).to contain_exactly(:transactional, :broadcast)
      expect(flash[:notice]).to include("Transactional test handed to test")
      expect(flash[:notice]).to include("Broadcast test handed to test")
      expect(flash[:alert]).to be_nil
    end

    it "does the same for an explicit both" do
      post TEST_SEND, params: {recipient: "dev@example.org", stream: "both"}

      expect(streams_delivered).to contain_exactly(:transactional, :broadcast)
    end

    it "sends only the stream asked for" do
      post TEST_SEND, params: {recipient: "dev@example.org", stream: "broadcast"}

      expect(streams_delivered).to eq([:broadcast])
      expect(flash[:notice]).to include("Broadcast test handed to test")
      expect(flash[:notice]).not_to include("Transactional")
    end

    it "says in the message which stream it rode, so two in one inbox can be told apart" do
      post TEST_SEND, params: {recipient: "dev@example.org"}

      subjects = SparrowMail.deliveries.map(&:subject)
      expect(subjects).to include("SparrowKit test email (transactional)", "SparrowKit test email (broadcast)")
    end

    it "reports a failure on one stream beside a success on the other" do
      error = SparrowMail::AuthenticationError.new("provider said 401")
      allow(SparrowMail).to receive(:deliver).and_wrap_original do |original, message|
        if message[SparrowMail::Envelope::STREAM_HEADER].to_s == "broadcast"
          SparrowMail::Result.failed(error, recipients: ["dev@example.org"])
        else
          original.call(message)
        end
      end

      post TEST_SEND, params: {recipient: "dev@example.org"}

      expect(flash[:notice]).to include("Transactional test handed to test")
      expect(flash[:alert]).to start_with("Broadcast:")
      expect(flash[:alert]).to include("credentials")
      expect(flash[:alert]).to include("provider said 401")
    end

    it "holds each stream back on its own clock" do
      post TEST_SEND, params: {recipient: "dev@example.org", stream: "transactional"}
      post TEST_SEND, params: {recipient: "dev@example.org"}

      # The second press sends the broadcast test, which had not gone out,
      # and holds the transactional one, which had.
      expect(streams_delivered).to eq([:transactional, :broadcast])
      expect(flash[:notice]).to include("Broadcast test handed to test")
      expect(flash[:alert]).to include("A transactional test just went out")
    end

    it "refuses a stream this application does not send on, and sends nothing" do
      post TEST_SEND, params: {recipient: "dev@example.org", stream: "carrier_pigeon"}

      expect(SparrowMail.deliveries).to be_empty
      expect(flash[:alert]).to include("not a stream this application sends on")
      expect(flash[:alert]).to include("transactional, broadcast")
    end

    it "offers the choice on the page, naming each stream's provider" do
      get "/sparrowkit/mail"

      expect(response.body).to include(%(name="stream"))
      expect(response.body).to include(%(value="transactional"))
      expect(response.body).to include(%(value="broadcast"))
      expect(response.body).to match(/value="both"\s+checked/)
      expect(response.body).to include("Transactional, through Test")
      expect(response.body).to include("Broadcast, through Test")
    end
  end

  describe "with one provider for everything" do
    before { configure_mail }

    it "offers no choice, because there is only the one stream" do
      get "/sparrowkit/mail"

      expect(response.body).not_to include(%(name="stream"))
      expect(response.body).to include("It rides the transactional stream.")
    end

    it "refuses a broadcast test rather than routing it down the transactional stream" do
      # The library would refuse the unknown stream anyway; this is the panel
      # saying so before a send is attempted, in words about this page.
      post TEST_SEND, params: {recipient: "dev@example.org", stream: "broadcast"}

      expect(SparrowMail.deliveries).to be_empty
      expect(flash[:alert]).to include("not a stream this application sends on")
    end
  end
end
