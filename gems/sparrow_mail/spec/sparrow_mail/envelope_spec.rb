# frozen_string_literal: true

RSpec.describe SparrowMail::Envelope do
  describe ".from_mail" do
    it "extracts the sender's address and display name separately" do
      envelope = build_envelope(from: "Sparrow Support <help@example.com>")

      expect(envelope.from.email).to eq("help@example.com")
      expect(envelope.from.name).to eq("Sparrow Support")
    end

    it "leaves the display name nil when the address has no name" do
      envelope = build_envelope(from: "help@example.com")

      expect(envelope.from.name).to be_nil
    end

    it "extracts every recipient list" do
      envelope = build_envelope(
        to: ["a@example.org", "b@example.org"],
        cc: "c@example.org",
        bcc: "d@example.org",
        reply_to: "reply@example.com"
      )

      expect(envelope.to.map(&:email)).to eq(["a@example.org", "b@example.org"])
      expect(envelope.cc.map(&:email)).to eq(["c@example.org"])
      expect(envelope.bcc.map(&:email)).to eq(["d@example.org"])
      expect(envelope.reply_to.map(&:email)).to eq(["reply@example.com"])
    end

    it "returns empty lists rather than nil for absent recipient types" do
      envelope = build_envelope(cc: nil, bcc: nil, reply_to: nil)

      expect(envelope.cc).to eq([])
      expect(envelope.bcc).to eq([])
      expect(envelope.reply_to).to eq([])
    end

    it "collects every recipient across to, cc and bcc" do
      envelope = build_envelope(to: "a@example.org", cc: "c@example.org", bcc: "d@example.org")

      expect(envelope.all_recipients.map(&:email))
        .to contain_exactly("a@example.org", "c@example.org", "d@example.org")
    end

    it "extracts the subject" do
      expect(build_envelope(subject: "Your sign-in code").subject).to eq("Your sign-in code")
    end

    it "extracts both parts of a multipart message" do
      envelope = build_envelope(text: "plain version", html: "<p>rich version</p>")

      expect(envelope.text_body).to eq("plain version")
      expect(envelope.html_body).to eq("<p>rich version</p>")
    end

    it "extracts a plain-text-only message as the text body" do
      envelope = build_envelope(text: "just words", html: nil)

      expect(envelope.text_body).to eq("just words")
      expect(envelope.html_body).to be_nil
    end

    it "extracts an html-only message as the html body" do
      envelope = build_envelope(text: nil, html: "<p>markup</p>")

      expect(envelope.html_body).to eq("<p>markup</p>")
      expect(envelope.text_body).to be_nil
    end

    it "extracts attachments with their filename, type and decoded content" do
      envelope = build_envelope(attachments: {"report.txt" => "column,value\n1,2\n"})

      attachment = envelope.attachments.first
      expect(attachment.filename).to eq("report.txt")
      expect(attachment.mime_type).to eq("text/plain")
      expect(attachment.content).to eq("column,value\n1,2\n")
      expect(attachment.base64_content).to eq(Base64.strict_encode64("column,value\n1,2\n"))
    end

    it "marks inline attachments and carries their content id" do
      mail = build_mail
      mail.attachments["logo.png"] = "PNG-BYTES"
      mail.attachments["logo.png"].content_id = "<logo@sparrow>"
      mail.attachments["logo.png"].content_disposition = "inline; filename=logo.png"

      envelope = described_class.from_mail(mail)

      attachment = envelope.attachments.first
      expect(attachment).to be_inline
      expect(attachment.content_id).to eq("logo@sparrow")
    end

    it "does not treat attachments as body parts" do
      envelope = build_envelope(attachments: {"report.txt" => "attached words"})

      expect(envelope.text_body).to include(MailHelpers::SECRET_BODY)
      expect(envelope.text_body).not_to include("attached words")
    end

    it "keeps custom headers" do
      envelope = build_envelope(headers: {"X-App-Name" => "timeliner"})

      expect(envelope.headers).to include("X-App-Name" => "timeliner")
    end

    it "drops headers the envelope already models, so adapters cannot send them twice" do
      envelope = build_envelope

      expect(envelope.headers.keys.map(&:downcase))
        .not_to include("from", "to", "cc", "bcc", "subject", "reply-to", "content-type")
    end

    it "reads tags from the X-Sparrow-Tags control header" do
      envelope = build_envelope(headers: {"X-Sparrow-Tags" => "otp, transactional"})

      expect(envelope.tags).to eq(["otp", "transactional"])
    end

    it "reads metadata from the X-Sparrow-Metadata control header" do
      envelope = build_envelope(headers: {"X-Sparrow-Metadata" => '{"org_id":"42"}'})

      expect(envelope.metadata).to eq("org_id" => "42")
    end

    it "strips control headers so they never reach the provider as raw headers" do
      envelope = build_envelope(
        headers: {"X-Sparrow-Tags" => "otp", "X-Sparrow-Metadata" => '{"org_id":"42"}'}
      )

      expect(envelope.headers.keys.map(&:downcase))
        .not_to include("x-sparrow-tags", "x-sparrow-metadata")
    end

    it "ignores malformed metadata rather than failing the send" do
      envelope = build_envelope(headers: {"X-Sparrow-Metadata" => "not json at all"})

      expect(envelope.metadata).to eq({})
    end

    it "defaults tags and metadata to empty" do
      envelope = build_envelope

      expect(envelope.tags).to eq([])
      expect(envelope.metadata).to eq({})
    end

    it "carries the sandbox flag it was built with" do
      expect(build_envelope(sandbox: true)).to be_sandbox
      expect(build_envelope(sandbox: false)).not_to be_sandbox
    end

    it "keeps the original message available for transports that send raw MIME" do
      mail = build_mail
      envelope = described_class.from_mail(mail)

      expect(envelope.mail).to be(mail)
      expect(envelope.to_mime).to include("Subject: Your sign-in code")
    end
  end

  describe "never logging message bodies" do
    it "redacts the bodies from #inspect" do
      envelope = build_envelope

      expect(envelope.inspect).not_to include(MailHelpers::SECRET_BODY)
      expect(envelope.inspect).to include("text_body=[redacted]")
    end

    it "redacts the bodies from #to_s" do
      expect(build_envelope.to_s).not_to include(MailHelpers::SECRET_BODY)
    end

    it "redacts attachment content from #inspect" do
      envelope = build_envelope(attachments: {"secret.txt" => "SENSITIVE-ATTACHMENT"})

      expect(envelope.inspect).not_to include("SENSITIVE-ATTACHMENT")
    end

    it "keeps routing metadata visible in #inspect, which is what makes it useful" do
      envelope = build_envelope(to: "person@example.org")

      expect(envelope.inspect).to include("SparrowMail::Envelope")
      expect(envelope.inspect).to include("recipients=1")
    end

    it "exposes a log-safe summary containing no body content" do
      envelope = build_envelope(headers: {"X-Sparrow-Tags" => "otp"})

      summary = envelope.log_summary

      expect(summary).to include(recipients: 1, tags: ["otp"], sandbox: false)
      expect(summary.to_s).not_to include(MailHelpers::SECRET_BODY)
      expect(summary).not_to have_key(:subject)
    end
  end

  describe "validation" do
    it "raises a configuration error when there is no sender" do
      mail = build_mail
      mail.from = nil

      expect { described_class.from_mail(mail) }
        .to raise_error(SparrowMail::ConfigurationError, /sender/i)
    end

    it "raises a configuration error when there is no recipient" do
      mail = build_mail(to: nil)

      expect { described_class.from_mail(mail) }
        .to raise_error(SparrowMail::ConfigurationError, /recipient/i)
    end

    it "counts a bcc-only message as having a recipient" do
      mail = build_mail(to: nil, bcc: "hidden@example.org")

      expect { described_class.from_mail(mail) }.not_to raise_error
    end
  end
end
