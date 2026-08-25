# frozen_string_literal: true

require "action_mailer"

# The gem does not depend on ActionMailer at runtime, so this is the spec that
# proves the integration works when a host application does have it. It
# registers the delivery method the way the Railtie does, then drives a real
# ActionMailer class end to end.
# A real mailer, defined the way an application would define one. Nothing about
# writing a mailer changes when this gem is the delivery method, and this class
# existing at all is the assertion of that.
class SignInMailer < ActionMailer::Base
  def sign_in_code(to:, code:)
    headers[SparrowMail::Envelope::TAGS_HEADER] = "otp"

    mail(from: "no-reply@example.com", to: to, subject: "Your sign-in code") do |format|
      format.text { render plain: "Your code is #{code}" }
    end
  end
end

RSpec.describe SparrowMail::DeliveryMethod do
  before(:all) do
    ActionMailer::Base.add_delivery_method(:sparrow_mail, described_class)
  end

  before do
    ActionMailer::Base.delivery_method = :sparrow_mail
    ActionMailer::Base.perform_deliveries = true
    ActionMailer::Base.raise_delivery_errors = true
    SparrowMail.configure { |config| config.adapter = :test }
  end

  describe "delivering through ActionMailer" do
    it "delivers a mailer message through the configured adapter" do
      SignInMailer.sign_in_code(to: "person@example.org", code: "123456").deliver_now

      expect(SparrowMail.deliveries.size).to eq(1)
      expect(SparrowMail.deliveries.first.to.first.email).to eq("person@example.org")
    end

    it "carries the control headers through to the envelope" do
      SignInMailer.sign_in_code(to: "person@example.org", code: "123456").deliver_now

      expect(SparrowMail.deliveries.first.tags).to eq(["otp"])
    end

    it "routes a mailer's message by the stream it declares" do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.stream :broadcast, settings: {label: "bulk"}
      end

      message = SignInMailer.sign_in_code(to: "person@example.org", code: "1")
      message[SparrowMail::Envelope::STREAM_HEADER] = "broadcast"
      message.deliver_now

      expect(SparrowMail.deliveries.last.stream).to eq(:broadcast)
    end

    it "surfaces a delivery failure to the caller" do
      SparrowMail::Adapters::Test.fail_with(
        SparrowMail::RateLimitError,
        status_code: 429,
        payload: {"message" => "Too many requests"}
      )

      expect { SignInMailer.sign_in_code(to: "a@example.org", code: "1").deliver_now }
        .to raise_error(SparrowMail::RateLimitError)
    end

    it "respects ActionMailer's perform_deliveries switch" do
      ActionMailer::Base.perform_deliveries = false

      SignInMailer.sign_in_code(to: "a@example.org", code: "1").deliver_now

      expect(SparrowMail.deliveries).to be_empty
    end
  end

  describe "settings" do
    it "uses the globally configured adapter when given none" do
      expect(described_class.new.adapter).to be_a(SparrowMail::Adapters::Test)
    end

    it "builds its own adapter when the delivery method settings name one" do
      method = described_class.new(adapter: :postmark, api_key: "pm-key")

      expect(method.adapter).to be_a(SparrowMail::Adapters::Postmark)
    end

    it "passes the remaining settings to the adapter it builds" do
      method = described_class.new(adapter: :mailgun, api_key: "mg-key", domain: "mg.example.com")

      expect(method.adapter.settings).to include(api_key: "mg-key", domain: "mg.example.com")
      expect(method.adapter.settings).not_to have_key(:adapter)
    end

    it "does not memoise the global adapter, so reconfiguring at runtime takes effect" do
      method = described_class.new
      first = method.adapter
      SparrowMail.configure { |config| config.adapter = :test }

      expect(method.adapter).not_to be(first)
    end

    it "keeps credentials out of inspect" do
      method = described_class.new(adapter: :postmark, api_key: "pm-secret-token")

      expect(method.inspect).not_to include("pm-secret-token")
    end
  end
end
