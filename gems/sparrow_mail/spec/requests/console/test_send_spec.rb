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

  it "sends through the configured adapter, from the configured sender" do
    configure_mail

    post TEST_SEND, params: {recipient: "dev@example.org"}

    expect(SparrowMail.deliveries.size).to eq(1)
    envelope = SparrowMail.deliveries.last
    expect(envelope.to.map(&:email)).to include("dev@example.org")
    expect(envelope.from.email).to eq("kit@example.com")
    expect(flash[:notice]).to match(/test/i)
  end

  it "sends on the transactional stream, never the marketing one" do
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
end
