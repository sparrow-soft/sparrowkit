# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::Mailgun do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::MailgunDriver.new }
  end

  describe "the Mailgun form" do
    let(:driver) { Drivers::MailgunDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.stub_success(message_id: "<mg-1@mg.example.com>") }
    after { driver.reset! }

    def deliver(sandbox: false, **kwargs)
      klass = sandbox ? described_class.new(driver.settings.merge(sandbox: true)) : adapter
      klass.deliver!(SparrowMail::Conformance.build_message(**kwargs))
      driver.form
    end

    def field(form, name)
      form.filter_map { |key, value| value if key == name }
    end

    it "authenticates with HTTP basic auth as the api user" do
      deliver

      expect(driver.last_headers["Authorization"])
        .to eq("Basic #{Base64.strict_encode64("api:mailgun-conformance-key")}")
    end

    it "posts to the domain's messages endpoint" do
      deliver

      expect(driver.last_request.uri.path).to eq("/v3/mg.example.com/messages")
    end

    it "posts to a configured region base url" do
      eu = described_class.new(driver.settings.merge(base_url: "https://api.eu.mailgun.net/"))
      WebMock.stub_request(:post, "https://api.eu.mailgun.net/v3/mg.example.com/messages")
        .to_return(status: 200, body: JSON.generate({"id" => "eu-1"}))

      expect { eu.deliver!(SparrowMail::Conformance.build_message) }.not_to raise_error
    end

    it "repeats the to field once per recipient" do
      form = deliver(to: ["one@example.org", "two@example.org"])

      expect(field(form, "to")).to eq(["one@example.org", "two@example.org"])
    end

    it "sends both body parts" do
      form = deliver(text: "plain", html: "<p>rich</p>")

      expect(field(form, "text")).to eq(["plain"])
      expect(field(form, "html")).to eq(["<p>rich</p>"])
    end

    it "prefixes custom headers with h:" do
      form = deliver(headers: {"X-App-Name" => "timeliner"})

      expect(field(form, "h:X-App-Name")).to eq(["timeliner"])
    end

    it "sends reply-to as an h: header, which is how Mailgun takes it" do
      form = deliver(reply_to: "reply@example.com")

      expect(field(form, "h:Reply-To")).to eq(["reply@example.com"])
    end

    it "repeats o:tag once per tag" do
      form = deliver(headers: {SparrowMail::Envelope::TAGS_HEADER => "otp, transactional"})

      expect(field(form, "o:tag")).to eq(["otp", "transactional"])
    end

    it "prefixes metadata with v:" do
      form = deliver(headers: {SparrowMail::Envelope::METADATA_HEADER => '{"org_id":"42"}'})

      expect(field(form, "v:org_id")).to eq(["42"])
    end

    it "does not set testmode when sandbox is off" do
      expect(field(deliver, "o:testmode")).to be_empty
    end

    it "sets Mailgun's own testmode in sandbox mode" do
      expect(field(deliver(sandbox: true), "o:testmode")).to eq(["yes"])
    end

    it "sends attachments as file parts" do
      form = deliver(attachments: {"note.txt" => "hello"})

      expect(field(form, "attachment")).to eq(["hello"])
      expect(driver.last_body).to include('filename="note.txt"')
    end

    it "sends inline attachments under the inline field" do
      mail = SparrowMail::Conformance.build_message
      mail.attachments["logo.png"] = "PNGDATA"
      mail.attachments["logo.png"].content_disposition = "inline; filename=logo.png"
      adapter.deliver!(mail)

      expect(field(driver.form, "inline")).to eq(["PNGDATA"])
      expect(field(driver.form, "attachment")).to be_empty
    end

    it "reads the message id back from the id field" do
      result = adapter.deliver!(SparrowMail::Conformance.build_message)

      expect(result.message_id).to eq("<mg-1@mg.example.com>")
    end

    it "requires a domain as well as an api key" do
      expect { described_class.new(api_key: "k") }
        .to raise_error(SparrowMail::ConfigurationError, /domain/)
    end
  end
end
