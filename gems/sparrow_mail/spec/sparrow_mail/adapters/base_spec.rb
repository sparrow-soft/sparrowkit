# frozen_string_literal: true

RSpec.describe SparrowMail::Adapters::Base do
  let(:adapter) { FakeAdapters::Counting.new }
  let(:logger) { CapturingLogger.new }

  describe "the adapter contract" do
    it "refuses to pretend it delivered when the subclass implements nothing" do
      expect { FakeAdapters::Abstract.new.deliver!(build_mail) }
        .to raise_error(NotImplementedError, /deliver_envelope/)
    end

    it "rejects missing required settings at construction, before any send is attempted" do
      expect { FakeAdapters::RequiringSettings.new(api_key: "k") }
        .to raise_error(SparrowMail::ConfigurationError, /domain/)
    end

    it "accepts settings given as strings" do
      expect { FakeAdapters::RequiringSettings.new("api_key" => "k", "domain" => "d") }
        .not_to raise_error
    end

    it "treats a blank required setting as missing" do
      expect { FakeAdapters::RequiringSettings.new(api_key: "k", domain: "  ") }
        .to raise_error(SparrowMail::ConfigurationError, /domain/)
    end

    it "names itself, so results and log lines identify their transport" do
      expect(FakeAdapters::Counting.adapter_name).to eq(:counting)
    end
  end

  describe "#deliver!" do
    it "normalises a Mail::Message into an envelope and delivers it" do
      result = adapter.deliver!(build_mail(to: ["a@example.org", "b@example.org"]))

      expect(result.recipients).to eq(2)
      expect(result.adapter).to eq(:counting)
      expect(result.message_id).to eq("fake-message-id")
    end

    it "accepts an already-built envelope" do
      expect(adapter.deliver!(build_envelope).message_id).to eq("fake-message-id")
    end

    it "stamps the elapsed time onto the result" do
      expect(adapter.deliver!(build_mail).duration_ms).to be_a(Integer)
    end

    it "raises before calling the provider when the message has no recipient" do
      mail = build_mail(to: nil)

      expect { adapter.deliver!(mail) }.to raise_error(SparrowMail::ConfigurationError)
      expect(FakeAdapters::Counting.calls).to eq(0)
    end
  end

  describe "#deliver, the variant that returns a failure rather than raising it" do
    it "returns a successful result when the send works" do
      result = adapter.deliver(build_mail)

      expect(result).to be_success
      expect(result.message_id).to eq("fake-message-id")
    end

    it "returns a failed result instead of raising" do
      FakeAdapters::Counting.raise_with =
        SparrowMail::RateLimitError.new(adapter: :counting, status_code: 429)

      result = adapter.deliver(build_mail)

      expect(result).to be_failure
      expect(result.category).to eq(:rate_limited)
      expect(result.error).to be_a(SparrowMail::RateLimitError)
    end

    it "still calls the adapter exactly once" do
      FakeAdapters::Counting.raise_with = SparrowMail::ProviderError.new(adapter: :counting)

      adapter.deliver(build_mail)

      expect(FakeAdapters::Counting.calls).to eq(1)
    end

    it "keeps the body out of the returned failure" do
      FakeAdapters::Counting.raise_with = RuntimeError.new("on #{MailHelpers::SECRET_BODY}")

      result = adapter.deliver(build_mail)

      expect(result.to_h.to_s).not_to include(MailHelpers::SECRET_BODY)
    end

    # A misconfigured deployment should fall over, not quietly report failures
    # for every message it is asked to send.
    it "still raises a configuration error, because that is a caller bug" do
      expect { adapter.deliver(build_mail(to: nil)) }
        .to raise_error(SparrowMail::ConfigurationError)
    end
  end

  describe "inviolable rule: a send is never retried" do
    it "calls the adapter exactly once on success" do
      adapter.deliver!(build_mail)

      expect(FakeAdapters::Counting.calls).to eq(1)
    end

    [
      SparrowMail::AuthenticationError,
      SparrowMail::InvalidRecipientError,
      SparrowMail::RateLimitError,
      SparrowMail::ProviderError,
      SparrowMail::NetworkError
    ].each do |error_class|
      it "calls the adapter exactly once when it raises #{error_class}" do
        FakeAdapters::Counting.raise_with = error_class.new("failed", adapter: :counting)

        expect { adapter.deliver!(build_mail) }.to raise_error(error_class)
        expect(FakeAdapters::Counting.calls).to eq(1)
      end
    end

    it "calls the adapter exactly once when it raises something unexpected" do
      FakeAdapters::Counting.raise_with = RuntimeError.new("kaboom")

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::UnknownError)
      expect(FakeAdapters::Counting.calls).to eq(1)
    end

    it "calls the adapter exactly once when the connection dies mid-send" do
      FakeAdapters::Counting.raise_with = Errno::ECONNRESET.new

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::NetworkError)
      expect(FakeAdapters::Counting.calls).to eq(1)
    end

    it "calls the adapter exactly once when the send times out, the case most likely to tempt a retry" do
      FakeAdapters::Counting.raise_with = Net::ReadTimeout.new

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::NetworkError)
      expect(FakeAdapters::Counting.calls).to eq(1)
    end
  end

  describe "inviolable rule: message bodies are never logged" do
    before { SparrowMail.configure { |c| c.logger = logger } }

    it "logs a successful delivery without any body content" do
      adapter.deliver!(build_mail)

      expect(logger).not_to have_logged(MailHelpers::SECRET_BODY)
      expect(logger.lines).not_to be_empty
    end

    it "does not log the subject either, since subjects leak intent" do
      adapter.deliver!(build_mail(subject: "Your Timeliner matter was deleted"))

      expect(logger).not_to have_logged("Your Timeliner matter was deleted")
    end

    it "logs the routing metadata that makes a log line worth having" do
      adapter.deliver!(build_mail(to: ["a@example.org", "b@example.org"]))

      expect(logger).to have_logged("recipients=2")
      expect(logger).to have_logged("adapter=counting")
    end

    it "logs a failure without any body content" do
      FakeAdapters::Counting.raise_with =
        SparrowMail::ProviderError.new("boom", adapter: :counting)

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::ProviderError)
      expect(logger).not_to have_logged(MailHelpers::SECRET_BODY)
      expect(logger).to have_logged("ProviderError")
    end

    it "does not leak the body when an unexpected exception carries it in its message" do
      FakeAdapters::Counting.raise_with = RuntimeError.new("failed on #{MailHelpers::SECRET_BODY}")

      expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::UnknownError) { |error|
        expect(error.message).not_to include(MailHelpers::SECRET_BODY)
        expect(error.to_h.to_s).not_to include(MailHelpers::SECRET_BODY)
      }
      expect(logger).not_to have_logged(MailHelpers::SECRET_BODY)
    end

    it "stays silent when no logger is configured" do
      SparrowMail.configure { |c| c.logger = nil }

      expect { adapter.deliver!(build_mail) }.not_to raise_error
    end
  end

  describe "error translation" do
    it "passes our own error types through untouched" do
      original = SparrowMail::RateLimitError.new("slow down", adapter: :counting)
      FakeAdapters::Counting.raise_with = original

      expect { adapter.deliver!(build_mail) }.to raise_error(original)
    end

    # Unknown rather than ProviderError: an exception nobody anticipated is not
    # evidence that the provider is down.
    it "wraps an unexpected exception as an UnknownError naming the adapter" do
      FakeAdapters::Counting.raise_with = RuntimeError.new("kaboom")

      expect { adapter.deliver!(build_mail) }
        .to raise_error(SparrowMail::UnknownError) { |error|
          expect(error.adapter).to eq(:counting)
          expect(error.category).to eq(:unknown)
          expect(error.provider_message).to include("RuntimeError")
        }
    end

    it "wraps socket and timeout failures as NetworkError" do
      [Errno::ECONNREFUSED, SocketError, Net::OpenTimeout, Net::ReadTimeout, IOError].each do |klass|
        FakeAdapters::Counting.raise_with = klass.new

        expect { adapter.deliver!(build_mail) }.to raise_error(SparrowMail::NetworkError)
      end
    end

    describe ".error_for_status" do
      {
        400 => SparrowMail::InvalidRecipientError,
        401 => SparrowMail::AuthenticationError,
        403 => SparrowMail::AuthenticationError,
        404 => SparrowMail::ProviderError,
        422 => SparrowMail::InvalidRecipientError,
        429 => SparrowMail::RateLimitError,
        500 => SparrowMail::ProviderError,
        503 => SparrowMail::ProviderError
      }.each do |status, error_class|
        it "maps HTTP #{status} to #{error_class.name.split("::").last}" do
          expect(described_class.error_for_status(status)).to eq(error_class)
        end
      end
    end
  end

  describe "sandbox mode" do
    let(:adapter) { FakeAdapters::Counting.new(sandbox: true) }

    context "when the provider has no sandbox of its own" do
      it "does not contact the provider at all" do
        adapter.deliver!(build_mail)

        expect(FakeAdapters::Counting.calls).to eq(0)
      end

      it "returns a result that says so plainly" do
        result = adapter.deliver!(build_mail)

        expect(result).to be_sandbox
        expect(result).not_to be_delivered
      end

      it "records the message so a test or a staging environment can inspect it" do
        adapter.deliver!(build_mail(subject: "Held back"))

        expect(SparrowMail.deliveries.size).to eq(1)
        expect(SparrowMail.deliveries.first.subject).to eq("Held back")
      end
    end

    context "when the provider has a sandbox of its own" do
      before { FakeAdapters::Counting.native_sandbox = true }

      it "does contact the provider, so the full request path is exercised" do
        adapter.deliver!(build_mail)

        expect(FakeAdapters::Counting.calls).to eq(1)
      end

      it "still marks the result as sandboxed, whatever the adapter returned" do
        expect(adapter.deliver!(build_mail)).to be_sandbox
      end

      it "still records the message locally" do
        adapter.deliver!(build_mail)

        expect(SparrowMail.deliveries.size).to eq(1)
      end
    end

    it "records nothing when not in sandbox mode" do
      FakeAdapters::Counting.new.deliver!(build_mail)

      expect(SparrowMail.deliveries).to be_empty
    end
  end
end
