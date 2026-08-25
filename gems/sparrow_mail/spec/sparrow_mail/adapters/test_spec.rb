# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::Test do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::TestDriver.new }
  end

  describe "recording instead of sending" do
    let(:adapter) { described_class.new }

    it "records every message it is given" do
      adapter.deliver!(build_mail(subject: "First"))
      adapter.deliver!(build_mail(subject: "Second"))

      expect(SparrowMail.deliveries.map(&:subject)).to eq(["First", "Second"])
    end

    it "records envelopes, so a test can assert on parsed recipients and bodies" do
      adapter.deliver!(build_mail(to: "person@example.org"))

      delivery = SparrowMail.deliveries.first
      expect(delivery).to be_a(SparrowMail::Envelope)
      expect(delivery.to.first.email).to eq("person@example.org")
      expect(delivery.text_body).to include(MailHelpers::SECRET_BODY)
    end

    it "records exactly once in sandbox mode, not twice" do
      described_class.new(sandbox: true).deliver!(build_mail)

      expect(SparrowMail.deliveries.size).to eq(1)
    end

    it "makes up a message id when none is set" do
      expect(adapter.deliver!(build_mail).message_id).to start_with("test-")
    end

    it "uses a message id when one is set" do
      described_class.next_message_id = "chosen-id"

      expect(adapter.deliver!(build_mail).message_id).to eq("chosen-id")
    end

    it "touches no network" do
      expect { adapter.deliver!(build_mail) }.not_to raise_error
    end
  end

  describe "injecting failures" do
    let(:adapter) { described_class.new }

    it "raises the configured error class" do
      described_class.fail_with(SparrowMail::RateLimitError)

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::RateLimitError)
    end

    it "keeps raising until told to stop" do
      described_class.fail_with(SparrowMail::ProviderError)
      2.times { expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::ProviderError) }

      described_class.stop_failing

      expect { adapter.deliver!(build_mail) }.not_to raise_error
    end

    it "carries the status code onto the error" do
      described_class.fail_with(SparrowMail::ProviderError, status_code: 503)

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::DeliveryError) { |e|
        expect(e.status_code).to eq(503)
      }
    end

    # An injected payload goes through the redactor exactly as a real provider's
    # would, so an application's error handling is tested against the shape it
    # will actually see rather than a friendlier one.
    it "redacts an injected payload the same way a real provider's is redacted" do
      described_class.fail_with(
        SparrowMail::InvalidRecipientError,
        payload: {
          "message" => "rejected: #{MailHelpers::SECRET_BODY}",
          "submitted_body" => MailHelpers::SECRET_BODY
        }
      )

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::DeliveryError) { |e|
        expect(e.message).not_to include(MailHelpers::SECRET_BODY)
        expect(e.provider_message).to include("rejected:")
      }
    end

    it "records nothing when the send fails" do
      described_class.fail_with(SparrowMail::ProviderError)

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::ProviderError)
      expect(SparrowMail.deliveries).to be_empty
    end
  end

  describe "state between tests" do
    it "is cleared by reset!" do
      described_class.fail_with(SparrowMail::ProviderError)
      described_class.next_message_id = "x"
      described_class.new.deliver!(build_mail) rescue nil # rubocop:disable Style/RescueModifier

      described_class.reset!

      expect(described_class.failure).to be_nil
      expect(described_class.next_message_id).to be_nil
      expect(described_class.call_count).to eq(0)
      expect(described_class.last_envelope).to be_nil
    end
  end
end
