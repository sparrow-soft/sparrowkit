# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::SendGrid do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::SendGridDriver.new }
  end

  describe "the SendGrid v3 payload" do
    let(:driver) { Drivers::SendGridDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.stub_success(message_id: "sg-1") }
    after { driver.reset! }

    def deliver(sandbox: false, **kwargs)
      klass = sandbox ? described_class.new(driver.settings.merge(sandbox: true)) : adapter
      klass.deliver!(SparrowMail::Conformance.build_message(**kwargs))
      driver.last_json
    end

    it "authenticates with a bearer token" do
      deliver

      expect(driver.last_headers["Authorization"]).to eq("Bearer sendgrid-conformance-key")
    end

    it "puts recipients inside a personalization" do
      payload = deliver(to: "Person <person@example.org>", cc: "cc@example.org")

      expect(payload["personalizations"].first["to"])
        .to eq([{"email" => "person@example.org", "name" => "Person"}])
      expect(payload["personalizations"].first["cc"]).to eq([{"email" => "cc@example.org"}])
    end

    # SendGrid rejects a payload whose content array puts html before plain.
    it "orders content with text/plain before text/html" do
      payload = deliver(text: "plain", html: "<p>rich</p>")

      expect(payload["content"]).to eq([
        {"type" => "text/plain", "value" => "plain"},
        {"type" => "text/html", "value" => "<p>rich</p>"}
      ])
    end

    it "sends a single content part when the message has only one" do
      expect(deliver(text: "plain", html: nil)["content"])
        .to eq([{"type" => "text/plain", "value" => "plain"}])
    end

    it "maps tags to categories" do
      payload = deliver(headers: {SparrowMail::Envelope::TAGS_HEADER => "otp, transactional"})

      expect(payload["categories"]).to eq(["otp", "transactional"])
    end

    it "maps metadata to custom_args on the personalization" do
      payload = deliver(headers: {SparrowMail::Envelope::METADATA_HEADER => '{"org_id":"42"}'})

      expect(payload["personalizations"].first["custom_args"]).to eq("org_id" => "42")
    end

    it "sends reply_to as a single object, not a list" do
      expect(deliver(reply_to: "reply@example.com")["reply_to"]).to eq("email" => "reply@example.com")
    end

    it "attaches files with a disposition" do
      payload = deliver(attachments: {"note.txt" => "hello"})

      expect(payload["attachments"]).to eq([{
        "content" => Base64.strict_encode64("hello"),
        "filename" => "note.txt",
        "type" => "text/plain",
        "disposition" => "attachment"
      }])
    end

    it "does not set sandbox mode when it is off" do
      expect(deliver).not_to have_key("mail_settings")
    end

    it "sets SendGrid's own sandbox mode when it is on" do
      expect(deliver(sandbox: true)["mail_settings"]).to eq("sandbox_mode" => {"enable" => true})
    end

    it "reads the message id from the X-Message-Id response header" do
      result = adapter.deliver!(SparrowMail::Conformance.build_message)

      expect(result.message_id).to eq("sg-1")
    end

    it "accepts the 202 with an empty body that SendGrid returns on success" do
      expect { adapter.deliver!(SparrowMail::Conformance.build_message) }.not_to raise_error
    end
  end
end
