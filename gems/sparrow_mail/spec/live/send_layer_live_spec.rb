# frozen_string_literal: true

# The one test in this suite that talks to a real provider.
#
# Everything else runs against stubbed responses, which proves the adapter does
# what we believe the API does. This proves we believe the right thing. It is
# skipped unless SENDLAYER_SANDBOX_KEY is set, so it never runs in CI by
# accident and never needs a credential committed anywhere.
#
#   SENDLAYER_SANDBOX_KEY=... \
#   SPARROW_MAIL_SMOKE_TO=you@example.com \
#   SPARROW_MAIL_SMOKE_FROM=verified-sender@yourdomain.com \
#   bundle exec rspec spec/live
#
# The From address has to be one SendLayer has verified for the account, or the
# API rejects it — which is itself a useful thing for this test to tell you.
RSpec.describe "SendLayer, against the live API", :live do
  let(:api_key) { ENV["SENDLAYER_SANDBOX_KEY"] }
  let(:recipient) { ENV["SPARROW_MAIL_SMOKE_TO"] }
  let(:sender) { ENV["SPARROW_MAIL_SMOKE_FROM"] }
  let(:logger) { SparrowMail::Conformance::CapturingLogger.new }
  let(:secret) { "LIVE-SMOKE-#{Process.pid}" }

  before do
    if [api_key, recipient, sender].any? { |value| value.nil? || value.empty? }
      skip "set SENDLAYER_SANDBOX_KEY, SPARROW_MAIL_SMOKE_TO and SPARROW_MAIL_SMOKE_FROM to run"
    end

    WebMock.allow_net_connect!
    SparrowMail.configure { |config| config.logger = logger }
  end

  after { WebMock.disable_net_connect!(allow_localhost: true) }

  let(:message) do
    SparrowMail::Conformance.build_message(
      from: sender,
      to: recipient,
      subject: "sparrow_mail live smoke test",
      text: "This is a live smoke test. Marker: #{secret}",
      html: "<p>This is a live smoke test. Marker: #{secret}</p>"
    )
  end

  it "delivers and returns the provider's message id" do
    result = SparrowMail::Adapters::SendLayer.new(api_key: api_key).deliver!(message)

    expect(result).to be_success
    expect(result).to be_delivered
    expect(result.message_id).not_to be_nil
  end

  it "keeps the body out of the log against a real response, not just a stubbed one" do
    SparrowMail::Adapters::SendLayer.new(api_key: api_key).deliver!(message)

    expect(logger.text).not_to include(secret)
  end

  it "surfaces a bad credential as an AuthenticationError" do
    adapter = SparrowMail::Adapters::SendLayer.new(api_key: "#{api_key}-definitely-wrong")

    expect { adapter.deliver!(message) }.to raise_error(SparrowMail::AuthenticationError)
  end
end
