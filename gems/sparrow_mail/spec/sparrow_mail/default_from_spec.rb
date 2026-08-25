# frozen_string_literal: true

# A default from-address is configuration, not something every mailer should
# have to restate. It also means the address lives in one place when it has to
# change, which it does whenever a sending domain does.
RSpec.describe "the default from address" do
  let(:adapter) { SparrowMail::Adapters::Test.new }

  def mail_without_sender
    Mail.new.tap do |mail|
      mail.to = "person@example.org"
      mail.subject = "Hello"
      mail.body = "Body"
    end
  end

  context "when configured" do
    before do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.default_from = "Sparrow <no-reply@example.com>"
      end
    end

    it "fills in a missing sender" do
      SparrowMail.deliver!(mail_without_sender)

      envelope = SparrowMail.deliveries.first
      expect(envelope.from.email).to eq("no-reply@example.com")
      expect(envelope.from.name).to eq("Sparrow")
    end

    it "does not override a sender the message already has" do
      SparrowMail.deliver!(
        Mail.new do
          from "specific@example.com"
          to "person@example.org"
          subject "Hello"
          body "Body"
        end
      )

      expect(SparrowMail.deliveries.first.from.email).to eq("specific@example.com")
    end

    it "reads from SPARROW_MAIL_DEFAULT_FROM" do
      config = SparrowMail::Configuration.new(
        {"SPARROW_MAIL_DEFAULT_FROM" => "env@example.com"}
      )

      expect(config.default_from).to eq("env@example.com")
    end
  end

  context "when not configured" do
    before { SparrowMail.configure { |config| config.adapter = :test } }

    it "still refuses a message with no sender, rather than inventing one" do
      expect { SparrowMail.deliver!(mail_without_sender) }
        .to raise_error(SparrowMail::ConfigurationError, /sender/i)
    end
  end
end
