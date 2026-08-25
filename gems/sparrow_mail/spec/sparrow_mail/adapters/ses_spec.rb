# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::SES do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::SESDriver.new }
  end

  describe "the SES request" do
    let(:driver) { Drivers::SESDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.stub_success(message_id: "ses-1") }
    after { driver.reset! }

    def deliver(**kwargs)
      adapter.deliver!(SparrowMail::Conformance.build_message(**kwargs))
      JSON.parse(driver.last_body)
    end

    def raw_mime
      Base64.decode64(JSON.parse(driver.last_body).dig("Content", "Raw", "Data"))
    end

    # The AWS SDK retries by default, which would break the never-retry rule
    # from inside a dependency. This is the assertion that catches an SDK
    # upgrade quietly changing the default back.
    it "builds a client that will not retry" do
      expect(adapter.send(:client).config.retry_limit).to eq(0)
    end

    it "uses the configured region" do
      expect(adapter.send(:client).config.region).to eq("us-east-1")
    end

    it "uses explicit credentials when given" do
      expect(adapter.send(:client).config.credentials.credentials.access_key_id)
        .to eq("AKIACONFORMANCEKEY")
    end

    it "leaves credentials to the AWS SDK's own chain when not given" do
      adapter = described_class.new(region: "eu-west-1")

      expect(adapter.send(:client_options)).not_to have_key(:credentials)
    end

    it "posts the message as raw MIME rather than rebuilding it" do
      deliver

      expect(raw_mime).to include("Subject: Your sign-in code")
      expect(raw_mime).to include("MIME-Version")
    end

    it "preserves attachments through the raw MIME, without re-encoding them" do
      deliver(attachments: {"note.txt" => "hello"})

      expect(raw_mime).to include("note.txt")
    end

    it "states the destination explicitly, so bcc recipients are actually addressed" do
      payload = deliver(to: "a@example.org", cc: "c@example.org", bcc: "b@example.org")

      expect(payload["Destination"]).to eq(
        "ToAddresses" => ["a@example.org"],
        "CcAddresses" => ["c@example.org"],
        "BccAddresses" => ["b@example.org"]
      )
    end

    it "maps metadata onto SES message tags" do
      payload = deliver(headers: {SparrowMail::Envelope::METADATA_HEADER => '{"org_id":"42"}'})

      expect(payload["EmailTags"]).to eq([{"Name" => "org_id", "Value" => "42"}])
    end

    # SES rejects the whole message if a tag value contains anything outside
    # [A-Za-z0-9_-], so sanitising beats failing the send.
    it "sanitises tag values SES would reject" do
      payload = deliver(headers: {SparrowMail::Envelope::METADATA_HEADER => '{"path":"/a/b c"}'})

      expect(payload["EmailTags"]).to eq([{"Name" => "path", "Value" => "_a_b_c"}])
    end

    it "omits EmailTags when there is no metadata" do
      expect(deliver).not_to have_key("EmailTags")
    end

    # SES message tags are name/value pairs, which fits metadata and not tags.
    # The control headers used to reach SES inside the raw MIME, which was
    # leakage of this gem's private vocabulary rather than tag support.
    it "does not publish the control headers to SES inside the raw MIME" do
      deliver(headers: {
        SparrowMail::Envelope::TAGS_HEADER => "otp",
        SparrowMail::Envelope::STREAM_HEADER => "broadcast",
        SparrowMail::Envelope::METADATA_HEADER => '{"org_id":"42"}'
      })

      expect(raw_mime).not_to include("X-Sparrow-Tags")
      expect(raw_mime).not_to include("X-Sparrow-Stream")
      expect(raw_mime).not_to include("X-Sparrow-Metadata")
    end

    it "still sends the caller's own custom headers in the MIME" do
      deliver(headers: {"X-App-Name" => "timeliner"})

      expect(raw_mime).to include("X-App-Name: timeliner")
    end

    it "includes a configuration set when one is configured" do
      adapter = described_class.new(driver.settings.merge(configuration_set_name: "tracking"))
      adapter.deliver!(SparrowMail::Conformance.build_message)

      expect(JSON.parse(driver.last_body)["ConfigurationSetName"]).to eq("tracking")
    end

    it "reads the message id back from the response" do
      expect(adapter.deliver!(SparrowMail::Conformance.build_message).message_id).to eq("ses-1")
    end

    it "requires a region" do
      expect { described_class.new({}) }
        .to raise_error(SparrowMail::ConfigurationError, /region/)
    end
  end

  describe "classifying SES errors" do
    let(:driver) { Drivers::SESDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    after { driver.reset! }

    def expect_error(type, status)
      WebMock.stub_request(:post, driver.endpoint).to_return(
        status: status,
        headers: {"Content-Type" => "application/x-amz-json-1.1", "x-amzn-ErrorType" => "#{type}:"},
        body: JSON.generate({"__type" => type, "message" => "nope"})
      )

      expect { adapter.deliver!(SparrowMail::Conformance.build_message) }
    end

    it "treats MessageRejected as an invalid recipient" do
      expect_error("MessageRejected", 400).to raise_error(SparrowMail::InvalidRecipientError)
    end

    it "treats an unverified sending domain as an invalid recipient" do
      expect_error("MailFromDomainNotVerifiedException", 400)
        .to raise_error(SparrowMail::InvalidRecipientError)
    end

    it "treats TooManyRequestsException as a rate limit" do
      expect_error("TooManyRequestsException", 429).to raise_error(SparrowMail::RateLimitError)
    end

    it "treats AccessDeniedException as an authentication failure" do
      expect_error("AccessDeniedException", 403).to raise_error(SparrowMail::AuthenticationError)
    end

    # SES answers nearly everything with a 400, so a suspended account would
    # otherwise be reported as a bad recipient address, sending whoever reads
    # the error off to check the recipient list.
    it "treats a suspended account as the provider being down, not a bad recipient" do
      expect_error("AccountSuspendedException", 400).to raise_error(SparrowMail::ProviderError)
    end

    it "treats paused sending as the provider being down" do
      expect_error("SendingPausedException", 400).to raise_error(SparrowMail::ProviderError)
    end

    it "falls back to the HTTP status for an unfamiliar error type" do
      expect_error("SomeNewException", 500).to raise_error(SparrowMail::ProviderError)
    end

    it "records the SES error code on the error" do
      expect_error("MessageRejected", 400).to raise_error(SparrowMail::DeliveryError) { |error|
        expect(error.provider_code.to_s).to include("message_rejected").or include("MessageRejected")
      }
    end

    it "reports a missing region as a configuration problem, not a delivery failure" do
      expect { described_class.new(region: "  ") }
        .to raise_error(SparrowMail::ConfigurationError)
    end
  end
end
