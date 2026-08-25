# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::Postmark do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::PostmarkDriver.new }
  end

  describe "the Postmark payload" do
    let(:driver) { Drivers::PostmarkDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.stub_success(message_id: "pm-1") }
    after { driver.reset! }

    def deliver(sandbox: false, **kwargs)
      klass = sandbox ? described_class.new(driver.settings.merge(sandbox: true)) : adapter
      klass.deliver!(SparrowMail::Conformance.build_message(**kwargs))
      driver.last_json
    end

    it "authenticates with the server token header" do
      deliver

      expect(driver.last_headers["X-Postmark-Server-Token"]).to eq("postmark-conformance-token")
    end

    it "sends recipients as comma-separated strings, which is Postmark's format" do
      payload = deliver(to: ["one@example.org", "Two <two@example.org>"])

      expect(payload["To"]).to eq("one@example.org, Two <two@example.org>")
    end

    it "sends the display name inline in the From string" do
      expect(deliver(from: "Sparrow <help@example.com>")["From"])
        .to eq("Sparrow <help@example.com>")
    end

    it "defaults to the outbound message stream" do
      expect(deliver["MessageStream"]).to eq("outbound")
    end

    it "uses a configured message stream" do
      adapter = described_class.new(driver.settings.merge(message_stream: "broadcast"))
      adapter.deliver!(SparrowMail::Conformance.build_message)

      expect(driver.last_json["MessageStream"]).to eq("broadcast")
    end

    it "sends headers as Name/Value pairs" do
      payload = deliver(headers: {"X-App-Name" => "timeliner"})

      expect(payload["Headers"]).to include({"Name" => "X-App-Name", "Value" => "timeliner"})
    end

    it "uses the first tag as Postmark's single Tag" do
      payload = deliver(headers: {SparrowMail::Envelope::TAGS_HEADER => "otp, transactional"})

      expect(payload["Tag"]).to eq("otp")
    end

    it "preserves the full tag list in metadata rather than dropping the rest" do
      payload = deliver(headers: {SparrowMail::Envelope::TAGS_HEADER => "otp, transactional"})

      expect(payload["Metadata"]["sparrow_tags"]).to eq("otp,transactional")
    end

    it "keeps caller metadata alongside the tag list" do
      payload = deliver(headers: {
        SparrowMail::Envelope::TAGS_HEADER => "otp",
        SparrowMail::Envelope::METADATA_HEADER => '{"org_id":"42"}'
      })

      expect(payload["Metadata"]).to include("org_id" => "42", "sparrow_tags" => "otp")
    end

    it "omits Metadata entirely when there is none" do
      expect(deliver).not_to have_key("Metadata")
    end

    it "base64-encodes attachments" do
      payload = deliver(attachments: {"note.txt" => "hello"})

      expect(payload["Attachments"]).to eq([{
        "Name" => "note.txt",
        "Content" => Base64.strict_encode64("hello"),
        "ContentType" => "text/plain"
      }])
    end

    # Postmark models streams natively and creates both of these on every
    # server. Sending bulk mail down "outbound" is what Postmark suspends
    # accounts for, so the default has to follow the message rather than be a
    # single hardcoded value.
    it "sends transactional mail on the outbound stream by default" do
      expect(deliver["MessageStream"]).to eq("outbound")
    end

    it "sends broadcast mail on the broadcast stream by default" do
      payload = deliver(headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"})

      expect(payload["MessageStream"]).to eq("broadcast")
    end

    it "uses a stream id the configuration names, over the default" do
      adapter = described_class.new(driver.settings.merge(message_stream: "newsletters"))
      adapter.deliver!(
        SparrowMail::Conformance.build_message(
          headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"}
        )
      )

      expect(driver.last_json["MessageStream"]).to eq("newsletters")
    end

    it "passes an unrecognised stream name through as the Postmark stream id" do
      payload = deliver(headers: {SparrowMail::Envelope::STREAM_HEADER => "product-updates"})

      expect(payload["MessageStream"]).to eq("product-updates")
    end

    it "swaps in Postmark's test token in sandbox mode" do
      deliver(sandbox: true)

      expect(driver.last_headers["X-Postmark-Server-Token"]).to eq(described_class::SANDBOX_TOKEN)
    end
  end

  describe "classifying Postmark's error codes" do
    let(:driver) { Drivers::PostmarkDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    after { driver.reset! }

    def expect_error(code, status: 422)
      WebMock.stub_request(:post, driver.endpoint).to_return(
        status: status,
        headers: {"Content-Type" => "application/json"},
        body: JSON.generate({"ErrorCode" => code, "Message" => "nope"})
      )

      expect { adapter.deliver!(SparrowMail::Conformance.build_message) }
    end

    # Postmark answers 422 for everything from an unconfirmed sender signature
    # to a suppressed address, so the numeric code has to decide, not the status.
    it "treats an inactive recipient (406) as an invalid recipient" do
      expect_error(406).to raise_error(SparrowMail::InvalidRecipientError)
    end

    it "treats an invalid email request (300) as an invalid recipient" do
      expect_error(300).to raise_error(SparrowMail::InvalidRecipientError)
    end

    it "treats a sender signature problem (400) as an authentication failure" do
      expect_error(400).to raise_error(SparrowMail::AuthenticationError)
    end

    it "treats code 429 as a rate limit even on a 422 response" do
      expect_error(429).to raise_error(SparrowMail::RateLimitError)
    end

    it "falls back to the HTTP status for codes it does not recognise" do
      expect_error(9999, status: 500).to raise_error(SparrowMail::ProviderError)
    end

    it "records the provider code on the error" do
      expect_error(406).to raise_error(SparrowMail::DeliveryError) { |error|
        expect(error.provider_code).to eq(406)
      }
    end
  end
end
