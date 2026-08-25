# frozen_string_literal: true

RSpec.describe SparrowMail::Redactor do
  let(:envelope) { build_envelope }
  let(:secret) { MailHelpers::SECRET_BODY }

  describe ".provider_message" do
    it "extracts the diagnostic text from a flat provider payload" do
      message = described_class.provider_message({"message" => "Sender signature not confirmed"})

      expect(message).to eq("Sender signature not confirmed")
    end

    it "recognises the several key spellings providers use" do
      expect(described_class.provider_message({"Message" => "Postmark says no"}))
        .to eq("Postmark says no")
      expect(described_class.provider_message({"error" => "Mailgun says no"}))
        .to eq("Mailgun says no")
      expect(described_class.provider_message({"detail" => "SES says no"}))
        .to eq("SES says no")
    end

    it "flattens a list of errors the way SendGrid returns them" do
      payload = {"errors" => [{"message" => "bad address", "field" => "personalizations.0.to.0.email"}]}

      message = described_class.provider_message(payload)

      expect(message).to include("bad address")
      expect(message).to include("personalizations.0.to.0.email")
    end

    it "drops keys that are not on the allowlist, because providers echo submissions back" do
      payload = {"message" => "rejected", "HtmlBody" => secret, "TextBody" => secret}

      message = described_class.provider_message(payload)

      expect(message).to eq("rejected")
      expect(message).not_to include(secret)
    end

    it "drops nested unknown keys too" do
      payload = {"errors" => [{"message" => "rejected", "submitted_content" => secret}]}

      expect(described_class.provider_message(payload)).not_to include(secret)
    end

    it "scrubs body content that a provider echoed into an allowlisted key" do
      payload = {"message" => "could not send: #{secret}"}

      message = described_class.provider_message(payload, envelope: envelope)

      expect(message).not_to include(secret)
      expect(message).to include("[redacted]")
      expect(message).to include("could not send:")
    end

    it "scrubs attachment content echoed back by a provider" do
      envelope = build_envelope(attachments: {"secret.txt" => "ATTACHED-SECRET-VALUE"})
      payload = {"message" => "attachment rejected: ATTACHED-SECRET-VALUE"}

      expect(described_class.provider_message(payload, envelope: envelope))
        .not_to include("ATTACHED-SECRET-VALUE")
    end

    it "handles a plain string payload" do
      expect(described_class.provider_message("Service Unavailable")).to eq("Service Unavailable")
    end

    it "scrubs a plain string payload that is really the whole message echoed back" do
      message = described_class.provider_message(envelope.to_mime, envelope: envelope)

      expect(message).not_to include(secret)
    end

    it "returns nil for an empty payload" do
      expect(described_class.provider_message(nil)).to be_nil
      expect(described_class.provider_message("")).to be_nil
      expect(described_class.provider_message("   ")).to be_nil
      expect(described_class.provider_message({})).to be_nil
    end

    it "returns nil when nothing on the allowlist is present" do
      expect(described_class.provider_message({"TextBody" => secret})).to be_nil
    end

    it "truncates long provider text, since an unbounded provider string is a body-shaped risk" do
      message = described_class.provider_message({"message" => "x" * 5_000})

      expect(message.length).to be <= described_class::MAX_LENGTH + 3
      expect(message).to end_with("...")
    end

    it "does not treat a short body line as a scrub pattern, which would redact everything" do
      envelope = build_envelope(text: "Hi", html: nil)

      expect(described_class.provider_message({"message" => "This is fine"}, envelope: envelope))
        .to eq("This is fine")
    end
  end

  describe ".scrub" do
    it "removes each distinct line of the body, so a truncated echo is caught too" do
      envelope = build_envelope(text: "Line one is long enough\nLine two is also long enough", html: nil)

      scrubbed = described_class.scrub("provider said: Line two is also long enough", envelope)

      expect(scrubbed).not_to include("Line two is also long enough")
    end

    it "returns the text untouched when there is no envelope to scrub against" do
      expect(described_class.scrub("anything at all", nil)).to eq("anything at all")
    end

    it "returns nil for nil" do
      expect(described_class.scrub(nil, envelope)).to be_nil
    end
  end
end
