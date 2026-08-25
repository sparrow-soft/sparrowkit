# frozen_string_literal: true

require "rspec"
require "sparrow_mail"
require "sparrow_mail/conformance/driver"

module SparrowMail
  # The behavioural contract every sparrow_mail adapter must satisfy.
  #
  # This is the real deliverable of the gem. The adapters themselves are thin
  # payload mapping; what an application actually relies on is that changing
  # `config.adapter` cannot change how delivery behaves, how failures surface,
  # or whether a message body can reach a log. That promise is worth nothing
  # unless it is executable, so here it is, run against every adapter in CI.
  #
  # It ships inside the gem rather than living in the gem's own spec directory
  # so that an adapter written anywhere is held to exactly the same standard:
  #
  #   require "sparrow_mail/conformance"
  #
  #   RSpec.describe MyCompany::CarrierPigeon do
  #     it_behaves_like "a sparrow_mail adapter" do
  #       let(:adapter_class) { described_class }
  #       let(:driver) { MyCompany::CarrierPigeonDriver.new }
  #     end
  #   end
  #
  # Requires `rspec`, and `webmock` if you use the supplied HTTP driver base.
  module Conformance
    # The five ways a send fails that an application has to tell apart, and the
    # error each must surface as. Every adapter maps its provider's vocabulary
    # onto exactly these.
    FAILURES = {
      authentication: AuthenticationError,
      invalid_recipient: InvalidRecipientError,
      rate_limit: RateLimitError,
      server_error: ProviderError,
      network_failure: NetworkError
    }.freeze

    # A body that is unmistakable if it ever escapes.
    SECRET = "CONFORMANCE-SECRET-BODY-90210"

    # And a short one, because the long one was the whole fixture and that is
    # how the defect survived.
    #
    # SECRET is 29 characters. The redactor's floor for a scrub pattern was
    # eight, so every assertion here passed while the one secret this library
    # actually protects -- sparrow_auth's six-digit sign-in code -- was returned
    # by every provider that echoed it. A fixture that cannot fail the way the
    # product fails is a fixture that proves the wrong thing.
    SHORT_SECRET = "483927"

    # Captures log output so the suite can assert on what did and did not reach
    # it. Blocks are evaluated immediately: a lazily-built line that would have
    # leaked a body still counts as a leak.
    class CapturingLogger
      attr_reader :entries

      def initialize
        @entries = []
      end

      %i[debug info warn error fatal unknown].each do |level|
        define_method(level) do |message = nil, &block|
          @entries << (block ? block.call : message).to_s
          true
        end
      end

      def add(_severity, message = nil, progname = nil, &block)
        @entries << (block ? block.call : (message || progname)).to_s
        true
      end

      def text
        entries.join("\n")
      end
    end

    class << self
      # A real Mail::Message. The suite builds genuine messages rather than
      # doubles because half of an adapter's job is coping with the shapes the
      # mail gem actually produces.
      def build_message(
        from: "Sparrow <no-reply@example.com>",
        to: "Recipient <person@example.org>",
        subject: "Your sign-in code",
        text: "Your code is #{SECRET}, or #{SHORT_SECRET} for short",
        html: "<p>Your code is #{SECRET}, or #{SHORT_SECRET} for short</p>",
        cc: nil,
        bcc: nil,
        reply_to: nil,
        headers: {},
        attachments: {}
      )
        Mail.new.tap do |mail|
          mail.from = from
          mail.to = to
          mail.cc = cc if cc
          mail.bcc = bcc if bcc
          mail.reply_to = reply_to if reply_to
          mail.subject = subject

          headers.each { |name, value| mail.header[name.to_s] = value }
          attachments.each { |name, body| mail.attachments[name] = body }

          if text && html
            mail.text_part = Mail::Part.new { body text }
            mail.html_part = Mail::Part.new do
              content_type "text/html; charset=UTF-8"
              body html
            end
          elsif html
            mail.content_type "text/html; charset=UTF-8"
            mail.body = html
          else
            mail.body = text
          end
        end
      end
    end
  end
end

# The including example group must define:
#
#   adapter_class  the class under test
#   driver         a SparrowMail::Conformance::Driver for its provider
#
RSpec.shared_examples "a sparrow_mail adapter" do
  let(:adapter) { adapter_class.new(driver.settings) }
  let(:sandbox_adapter) { adapter_class.new(driver.settings.merge(sandbox: true)) }
  let(:conformance_logger) { SparrowMail::Conformance::CapturingLogger.new }
  let(:secret) { SparrowMail::Conformance::SECRET }
  let(:short_secret) { SparrowMail::Conformance::SHORT_SECRET }

  def build_message(...)
    SparrowMail::Conformance.build_message(...)
  end

  let(:message) { build_message }

  before do
    SparrowMail.reset!
    SparrowMail.configure { |config| config.logger = conformance_logger }
    driver.reset!
  end

  after { driver.reset! }

  describe "[conformance] configuration" do
    it "is registered under a name" do
      expect(adapter_class.adapter_name).to be_a(Symbol)
    end

    it "refuses to build without its required settings" do
      adapter_class.required_settings.each do |setting|
        incomplete = driver.settings.reject { |key, _| key == setting }

        expect { adapter_class.new(incomplete) }
          .to raise_error(SparrowMail::ConfigurationError, /#{setting}/),
            "expected a missing #{setting} to be rejected at construction"
      end
    end

    it "does not print its credentials" do
      driver.settings.each_value do |value|
        next unless value.is_a?(String) && value.length > 6

        expect(adapter.inspect).not_to include(value)
      end
    end
  end

  describe "[conformance] delivery" do
    before { driver.stub_success(message_id: "provider-id-1") }

    it "delivers a message and reports which adapter did it" do
      result = adapter.deliver!(message)

      expect(result).to be_a(SparrowMail::Result)
      expect(result.adapter).to eq(adapter_class.adapter_name)
      expect(result).to be_delivered
    end

    it "reports the provider's message id" do
      expect(adapter.deliver!(message).message_id).to eq("provider-id-1")
    end

    it "reports how many recipients it was sent to" do
      multi = build_message(to: ["one@example.org", "two@example.org"], cc: "three@example.org")

      expect(adapter.deliver!(multi).recipients).to eq(3)
    end

    it "records how long the send took" do
      expect(adapter.deliver!(message).duration_ms).to be_a(Integer)
    end

    it "delivers a message carrying cc, bcc and reply-to" do
      full = build_message(
        cc: "cc@example.org",
        bcc: "bcc@example.org",
        reply_to: "reply@example.com"
      )

      expect { adapter.deliver!(full) }.not_to raise_error
    end

    it "delivers a plain-text-only message" do
      expect { adapter.deliver!(build_message(text: "just words", html: nil)) }.not_to raise_error
    end

    it "delivers an html-only message" do
      expect { adapter.deliver!(build_message(text: nil, html: "<p>markup</p>")) }.not_to raise_error
    end

    it "delivers a message with an attachment" do
      with_attachment = build_message(attachments: {"invoice.pdf" => "%PDF-1.4 fake"})

      expect { adapter.deliver!(with_attachment) }.not_to raise_error
    end

    it "refuses a message with no recipient, before contacting the provider" do
      expect { adapter.deliver!(build_message(to: nil)) }
        .to raise_error(SparrowMail::ConfigurationError)
      expect(driver.request_count).to eq(0)
    end
  end

  # The delivery block above proves a request was accepted. These prove the
  # message survived the trip. An adapter that quietly dropped the subject, or
  # sent only the first recipient, would pass every other test in this suite.
  describe "[conformance] the envelope reaches the provider intact" do
    before { driver.stub_success }

    it "sends the from address" do
      adapter.deliver!(build_message(from: "Sparrow Support <help@example.com>"))

      skip "driver does not report the sender" if driver.sent_from.nil?

      expect(driver.sent_from).to include("help@example.com")
    end

    it "sends every to recipient, not just the first" do
      adapter.deliver!(build_message(to: ["one@example.org", "two@example.org"]))

      skip "driver does not report recipients" if driver.sent_to.nil?

      expect(driver.sent_to).to contain_exactly("one@example.org", "two@example.org")
    end

    it "sends the subject" do
      adapter.deliver!(build_message(subject: "Your sign-in code"))

      skip "driver does not report the subject" if driver.sent_subject.nil?

      expect(driver.sent_subject).to include("Your sign-in code")
    end

    it "sends the reply-to address" do
      adapter.deliver!(build_message(reply_to: "reply@example.com"))

      skip "driver does not report reply-to" if driver.sent_reply_to.nil?

      expect(driver.sent_reply_to.join(" ")).to include("reply@example.com")
    end

    # Transactional mail is international. A subject that arrives mojibake is a
    # support ticket, and encoding bugs only show up on non-ASCII input.
    it "handles a UTF-8 subject" do
      subject = "Código de acceso · 確認 · Grüße"

      expect { adapter.deliver!(build_message(subject: subject)) }.not_to raise_error

      skip "driver does not report the subject" if driver.sent_subject.nil?

      expect(driver.sent_subject).to include("Código").or include("=?UTF-8?")
    end

    it "handles a UTF-8 body" do
      body = "Grüße und 確認 — your code follows"

      expect { adapter.deliver!(build_message(text: body, html: nil)) }.not_to raise_error
    end

    it "handles a long recipient list in one request" do
      recipients = (1..50).map { |n| "person#{n}@example.org" }

      result = adapter.deliver!(build_message(to: recipients))

      expect(result.recipients).to eq(50)
      expect(driver.request_count).to eq(1)
    end
  end

  # Streams keep bulk mail off the transactional sending reputation. Every
  # adapter has to carry the stream through, whether or not its provider has a
  # native equivalent, because the Result and the log line are how an
  # application proves after the fact which reputation a message went out on.
  describe "[conformance] streams" do
    before { driver.stub_success }

    it "reports the transactional stream by default" do
      expect(adapter.deliver!(message).stream).to eq(:transactional)
    end

    it "reports the stream the message named" do
      broadcast = build_message(headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"})

      expect(adapter.deliver!(broadcast).stream).to eq(:broadcast)
    end

    it "reports the stream on a failure too" do
      driver.reset!
      driver.stub_failure(:server_error)
      broadcast = build_message(headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"})

      expect(adapter.deliver(broadcast).stream).to eq(:broadcast)
    end

    it "does not send the stream control header as a raw header" do
      adapter.deliver!(build_message(headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"}))

      skip "provider has no concept of custom headers" if driver.sent_headers.nil?

      expect(driver.sent_headers.keys.map(&:downcase)).not_to include("x-sparrow-stream")
    end

    it "tells the provider which stream this is, where the provider has them" do
      adapter.deliver!(build_message(headers: {SparrowMail::Envelope::STREAM_HEADER => "broadcast"}))

      skip "provider has no stream concept of its own" if driver.sent_stream.nil?

      broadcast_value = driver.sent_stream
      driver.reset!
      driver.stub_success
      adapter.deliver!(message)

      expect(driver.sent_stream).not_to eq(broadcast_value),
        "the provider received the same stream for transactional and broadcast mail, " \
        "so it cannot keep their sending reputations apart"
    end
  end

  describe "[conformance] metadata and headers" do
    before { driver.stub_success }

    it "carries custom headers to the provider" do
      adapter.deliver!(build_message(headers: {"X-App-Name" => "example-app"}))

      skip "provider has no concept of custom headers" if driver.sent_headers.nil?

      expect(driver.sent_headers.transform_keys(&:downcase)).to include("x-app-name" => "example-app")
    end

    it "carries tags to the provider" do
      adapter.deliver!(
        build_message(headers: {SparrowMail::Envelope::TAGS_HEADER => "otp, transactional"})
      )

      skip "provider has no concept of tags" if driver.sent_tags.nil?

      expect(driver.sent_tags).to contain_exactly("otp", "transactional")
    end

    it "carries metadata to the provider" do
      adapter.deliver!(
        build_message(headers: {SparrowMail::Envelope::METADATA_HEADER => '{"org_id":"42"}'})
      )

      skip "provider has no concept of metadata" if driver.sent_metadata.nil?

      expect(driver.sent_metadata).to include("org_id" => "42")
    end
  end

  describe "[conformance] error surfacing" do
    SparrowMail::Conformance::FAILURES.each do |kind, error_class|
      it "raises #{error_class.name.split("::").last} when the provider signals #{kind}" do
        driver.stub_failure(kind)

        expect { adapter.deliver!(message) }.to raise_error(error_class)
      end
    end

    it "names the adapter on the error, so a multi-provider app can tell who failed" do
      driver.stub_failure(:server_error)

      expect { adapter.deliver!(message) }.to raise_error(SparrowMail::DeliveryError) { |error|
        expect(error.adapter).to eq(adapter_class.adapter_name)
      }
    end

    it "carries the recipient count on the error, which is safe to log" do
      driver.stub_failure(:server_error)

      expect { adapter.deliver!(message) }.to raise_error(SparrowMail::DeliveryError) { |error|
        expect(error.recipients).to eq(1)
      }
    end

    it "offers no retryable? hint, because the gem does not retry and neither should a caller" do
      driver.stub_failure(:server_error)

      expect { adapter.deliver!(message) }.to raise_error(SparrowMail::DeliveryError) { |error|
        expect(error).not_to respond_to(:retryable?)
      }
    end
  end

  describe "[conformance] inviolable rule: message bodies are never logged" do
    it "keeps the body out of the log on a successful delivery" do
      driver.stub_success

      adapter.deliver!(message)

      expect(conformance_logger.text).not_to include(secret)
    end

    it "keeps the subject out of the log too" do
      driver.stub_success

      adapter.deliver!(build_message(subject: "Matter 41 deleted"))

      expect(conformance_logger.text).not_to include("Matter 41 deleted")
    end

    SparrowMail::Conformance::FAILURES.each_key do |kind|
      it "keeps the body out of the log when the provider signals #{kind}" do
        driver.stub_failure(kind)

        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error)
        expect(conformance_logger.text).not_to include(secret)
      end
    end

    # A six-digit code, echoed back. Everything below is asserted for the long
    # secret too; this is the one that was failing silently.
    context "when the provider echoes back a short code" do
      before { driver.stub_echo(SparrowMail::Conformance::SHORT_SECRET) }

      it "keeps it out of the exception message" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error) { |error|
          expect(error.message).not_to include(short_secret)
        }
      end

      it "keeps it out of the exception's structured form" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::DeliveryError) { |error|
          expect(error.to_h.to_s).not_to include(short_secret)
        }
      end

      it "keeps it out of the log" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error)
        expect(conformance_logger.text).not_to include(short_secret)
      end
    end

    context "when the provider echoes the submitted message back in its error" do
      before { driver.stub_echo(SparrowMail::Conformance::SECRET) }

      it "keeps the body out of the exception message" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error) { |error|
          expect(error.message).not_to include(secret)
        }
      end

      it "keeps the body out of the exception's structured form" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::DeliveryError) { |error|
          expect(error.to_h.to_s).not_to include(secret)
        }
      end

      it "keeps the body out of the exception's inspect output" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error) { |error|
          expect(error.inspect).not_to include(secret)
        }
      end

      it "keeps the body out of the exception's to_s output" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error) { |error|
          expect(error.to_s).not_to include(secret)
        }
      end

      it "keeps the body out of the failed Result returned by #deliver" do
        result = adapter.deliver(message)

        expect(result).to be_failure
        expect(result.to_h.to_s).not_to include(secret)
        expect(result.inspect).not_to include(secret)
      end

      it "keeps the body out of the log" do
        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error)

        expect(conformance_logger.text).not_to include(secret)
      end
    end

    it "still logs something useful, or the rule would be satisfied by logging nothing" do
      driver.stub_success

      adapter.deliver!(message)

      expect(conformance_logger.text).to include(adapter_class.adapter_name.to_s)
      expect(conformance_logger.text).to include("recipients=1")
    end
  end

  describe "[conformance] inviolable rule: a send is never retried" do
    it "makes exactly one request on success" do
      driver.stub_success

      adapter.deliver!(message)

      expect(driver.request_count).to eq(1)
    end

    SparrowMail::Conformance::FAILURES.each_key do |kind|
      it "makes exactly one request when the provider signals #{kind}" do
        driver.stub_failure(kind)

        expect { adapter.deliver!(message) }.to raise_error(SparrowMail::Error)
        expect(driver.request_count).to eq(1),
          "#{kind} produced #{driver.request_count} requests. A send is never retried, " \
          "including by a transport's own default retry behaviour."
      end
    end

    it "makes exactly one request when the message has an attachment" do
      driver.stub_success

      adapter.deliver!(build_message(attachments: {"a.txt" => "x"}))

      expect(driver.request_count).to eq(1)
    end
  end

  describe "[conformance] sandbox mode" do
    before { driver.stub_success }

    it "marks the result as sandboxed" do
      expect(sandbox_adapter.deliver!(message)).to be_sandbox
    end

    it "records the message exactly once, so it can be inspected without an inbox" do
      sandbox_adapter.deliver!(message)

      expect(SparrowMail.deliveries.size).to eq(1)
      expect(SparrowMail.deliveries.first.to.first.email).to eq("person@example.org")
    end

    context "when the provider has a sandbox of its own" do
      before { skip "adapter has no native sandbox" unless adapter_class.native_sandbox? }

      it "still makes the request, so the full path is exercised" do
        sandbox_adapter.deliver!(message)

        expect(driver.request_count).to eq(1)
      end

      it "marks the request with the provider's own sandbox flag" do
        sandbox_adapter.deliver!(message)

        expect(driver.sandbox_marked?).to be(true)
      end
    end

    context "when the provider has no sandbox of its own" do
      before { skip "adapter has a native sandbox" if adapter_class.native_sandbox? }

      it "does not contact the provider at all" do
        sandbox_adapter.deliver!(message)

        expect(driver.request_count).to eq(0)
      end

      it "reports that nothing was actually delivered" do
        expect(sandbox_adapter.deliver!(message)).not_to be_delivered
      end
    end

    it "records nothing when sandbox mode is off" do
      skip "this adapter records every message by design" if driver.records_outside_sandbox?

      adapter.deliver!(message)

      expect(SparrowMail.deliveries).to be_empty
    end
  end
end
