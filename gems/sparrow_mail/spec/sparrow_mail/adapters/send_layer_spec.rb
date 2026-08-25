# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::SendLayer do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::SendLayerDriver.new }
  end

  # The conformance suite proves the behaviour is identical to every other
  # adapter. These prove the payload is actually SendLayer-shaped, which no
  # provider-neutral suite can check.
  describe "the SendLayer payload" do
    let(:driver) { Drivers::SendLayerDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.stub_success(message_id: "sl-1") }
    after { driver.reset! }

    def deliver(**kwargs)
      adapter.deliver!(SparrowMail::Conformance.build_message(**kwargs))
      driver.last_json
    end

    it "authenticates with a bearer token" do
      deliver

      expect(driver.last_headers["Authorization"]).to eq("Bearer sendlayer-conformance-key")
    end

    it "posts to the v1 email endpoint" do
      deliver

      uri = driver.last_request.uri
      expect(uri.host).to eq("console.sendlayer.com")
      expect(uri.path).to eq("/api/v1/email")
      expect(uri.scheme).to eq("https")
    end

    it "sends From as an object with name and email" do
      payload = deliver(from: "Sparrow Support <help@example.com>")

      expect(payload["From"]).to eq("email" => "help@example.com", "name" => "Sparrow Support")
    end

    it "omits the name when the address has none" do
      expect(deliver(from: "help@example.com")["From"]).to eq("email" => "help@example.com")
    end

    it "sends To as a list of objects" do
      payload = deliver(to: ["one@example.org", "two@example.org"])

      expect(payload["To"]).to eq([{"email" => "one@example.org"}, {"email" => "two@example.org"}])
    end

    it "sends both body parts and declares HTML content" do
      payload = deliver(text: "plain", html: "<p>rich</p>")

      expect(payload["PlainContent"]).to eq("plain")
      expect(payload["HTMLContent"]).to eq("<p>rich</p>")
      expect(payload["ContentType"]).to eq("HTML")
    end

    it "declares plain content when there is no html part" do
      payload = deliver(text: "plain", html: nil)

      expect(payload["ContentType"]).to eq("Plain")
      expect(payload).not_to have_key("HTMLContent")
    end

    it "omits recipient lists that are empty rather than sending empty arrays" do
      payload = deliver

      expect(payload).not_to have_key("Cc")
      expect(payload).not_to have_key("Bcc")
      expect(payload).not_to have_key("ReplyTo")
    end

    it "includes cc, bcc and reply-to when present" do
      payload = deliver(cc: "cc@example.org", bcc: "bcc@example.org", reply_to: "r@example.com")

      expect(payload["Cc"]).to eq([{"email" => "cc@example.org"}])
      expect(payload["Bcc"]).to eq([{"email" => "bcc@example.org"}])
      expect(payload["ReplyTo"]).to eq([{"email" => "r@example.com"}])
    end

    it "base64-encodes attachments with filename and type" do
      payload = deliver(attachments: {"report.csv" => "a,b\n1,2\n"})

      expect(payload["Attachments"]).to eq([{
        "FileName" => "report.csv",
        "FileType" => "text/csv",
        "Content" => Base64.strict_encode64("a,b\n1,2\n")
      }])
    end

    it "reads the message id back from MessageID" do
      expect(adapter.deliver!(SparrowMail::Conformance.build_message).message_id).to eq("sl-1")
    end

    it "survives a success response with no message id" do
      driver.reset!
      WebMock.stub_request(:post, driver.endpoint).to_return(status: 200, body: "")

      expect(adapter.deliver!(SparrowMail::Conformance.build_message).message_id).to be_nil
    end
  end
end
