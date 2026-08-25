# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::SMTP do
  it_behaves_like "a sparrow_mail adapter" do
    let(:adapter_class) { described_class }
    let(:driver) { Drivers::SMTPDriver.new }
  end

  describe "talking to a real SMTP server" do
    let(:driver) { Drivers::SMTPDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.reset! }
    after { driver.shutdown }

    it "delivers the whole message, headers and body together" do
      adapter.deliver!(SparrowMail::Conformance.build_message(subject: "Hello there"))

      data = driver.server.deliveries.last.data
      expect(data).to include("Subject: Hello there")
      expect(data).to include(SparrowMail::Conformance::SECRET)
    end

    it "sets the SMTP envelope sender and recipients" do
      adapter.deliver!(
        SparrowMail::Conformance.build_message(
          from: "no-reply@example.com",
          to: "a@example.org",
          bcc: "b@example.org"
        )
      )

      delivery = driver.server.deliveries.last
      expect(delivery.from).to eq("no-reply@example.com")
      expect(delivery.recipients).to contain_exactly("a@example.org", "b@example.org")
    end

    it "does not leak bcc recipients into the message headers" do
      adapter.deliver!(SparrowMail::Conformance.build_message(bcc: "hidden@example.org"))

      expect(driver.server.deliveries.last.data).not_to include("hidden@example.org")
    end

    # A control header forces the message to be rebuilt from stripped MIME,
    # and the mail gem deliberately omits Bcc from the encoded form. If the
    # SMTP envelope recipients were not restated, blind copies would silently
    # stop being delivered on exactly the messages that set a stream or a tag.
    context "when a control header forces the message to be rebuilt" do
      let(:message) do
        SparrowMail::Conformance.build_message(
          to: "visible@example.org",
          bcc: "hidden@example.org",
          headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"}
        )
      end

      it "still delivers to bcc recipients" do
        adapter.deliver!(message)

        expect(driver.server.deliveries.last.recipients)
          .to contain_exactly("visible@example.org", "hidden@example.org")
      end

      it "still keeps bcc out of the headers" do
        adapter.deliver!(message)

        expect(driver.server.deliveries.last.data).not_to include("hidden@example.org")
      end

      it "strips the control header from what the far end receives" do
        adapter.deliver!(message)

        expect(driver.server.deliveries.last.data).not_to include("X-Sparrow-Stream")
      end

      it "leaves the caller's own Mail object untouched" do
        adapter.deliver!(message)

        expect(message[SparrowMail::Envelope::STREAM_HEADER]).not_to be_nil
      end

      it "still delivers the body and the subject" do
        adapter.deliver!(message)

        data = driver.server.deliveries.last.data
        expect(data).to include("Subject: Your sign-in code")
        expect(data).to include(SparrowMail::Conformance::SECRET)
      end
    end

    it "delivers attachments" do
      adapter.deliver!(SparrowMail::Conformance.build_message(attachments: {"n.txt" => "hello"}))

      expect(driver.server.deliveries.last.data).to include("n.txt")
    end

    it "authenticates when credentials are configured" do
      expect { adapter.deliver!(SparrowMail::Conformance.build_message) }.not_to raise_error
    end

    # Postfix, Exim and Sendmail all answer a queued message this way. There is
    # no standard for it, so this is best-effort by design.
    it "reads the queue id out of the server's 250 response" do
      driver.stub_success(message_id: "4F1kD62Rz")

      result = adapter.deliver!(SparrowMail::Conformance.build_message)

      expect(result.message_id).to eq("4F1kD62Rz")
    end

    it "falls back to the message's own Message-ID when the server names no queue id" do
      driver.server.data_reply = "250 2.0.0 Ok\r\n"
      mail = SparrowMail::Conformance.build_message
      mail.message_id = "generated@example.com"

      expect(adapter.deliver!(mail).message_id).to eq("generated@example.com")
    end

    it "requires an address" do
      expect { described_class.new({}) }
        .to raise_error(SparrowMail::ConfigurationError, /address/)
    end

    it "defaults to the submission port" do
      expect(described_class.new(address: "smtp.example.com").send(:smtp_settings)[:port])
        .to eq(587)
    end

    it "passes TLS settings through to the transport" do
      settings = described_class.new(
        address: "smtp.example.com",
        enable_starttls_auto: false,
        openssl_verify_mode: "none"
      ).send(:smtp_settings)

      expect(settings[:enable_starttls_auto]).to be(false)
      expect(settings[:openssl_verify_mode]).to eq("none")
    end
  end

  describe "translating SMTP reply codes" do
    let(:driver) { Drivers::SMTPDriver.new }
    let(:adapter) { described_class.new(driver.settings) }

    before { driver.reset! }
    after { driver.shutdown }

    def expect_reply(code, at: :rcpt_to)
      case at
      when :rcpt_to then driver.server.rcpt_to_reply = "#{code} Nope\r\n"
      when :data then driver.server.data_reply = "#{code} Nope\r\n"
      when :auth then driver.server.auth_reply = "#{code} Nope\r\n"
      end

      expect { adapter.deliver!(SparrowMail::Conformance.build_message) }
    end

    it "treats 535 as an authentication failure" do
      expect_reply(535, at: :auth).to raise_error(SparrowMail::AuthenticationError)
    end

    it "treats 530 as an authentication failure" do
      expect_reply(530, at: :auth).to raise_error(SparrowMail::AuthenticationError)
    end

    it "treats 550 as an invalid recipient" do
      expect_reply(550).to raise_error(SparrowMail::InvalidRecipientError)
    end

    it "treats 553 as an invalid recipient" do
      expect_reply(553).to raise_error(SparrowMail::InvalidRecipientError)
    end

    it "treats 450 as a rate limit" do
      expect_reply(450).to raise_error(SparrowMail::RateLimitError)
    end

    it "treats 452 as a rate limit" do
      expect_reply(452).to raise_error(SparrowMail::RateLimitError)
    end

    # 4xx and 5xx do not map onto "temporary" and "permanent" here, because the
    # gem never retries either way. The classes describe the cause, not a
    # scheduling hint.
    it "treats 451 as a provider error rather than a rate limit" do
      expect_reply(451, at: :data).to raise_error(SparrowMail::ProviderError)
    end

    it "treats 554 as a provider error" do
      expect_reply(554, at: :data).to raise_error(SparrowMail::ProviderError)
    end

    it "records the SMTP status code on the error" do
      expect_reply(550).to raise_error(SparrowMail::DeliveryError) { |error|
        expect(error.status_code).to eq(550)
      }
    end

    it "reports a refused connection as a network error" do
      unreachable = described_class.new(address: "127.0.0.1", port: 1, open_timeout: 1)

      expect { unreachable.deliver!(SparrowMail::Conformance.build_message) }
        .to raise_error(SparrowMail::NetworkError)
    end
  end
end
