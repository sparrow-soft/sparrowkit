# frozen_string_literal: true

# Streams exist because mixing bulk mail and transactional mail through one
# sending identity damages the transactional one. Spam complaints against a
# newsletter drag down the deliverability of sign-in codes sent from the same
# reputation, and some providers suspend accounts for it.
#
# Providers that model this natively get the stream mapped onto their own
# concept. Providers that do not get separation the only way available to them:
# different credentials, a different sending domain, or a different relay,
# configured per stream. Either way the separation is real rather than notional.
RSpec.describe "streams" do
  describe SparrowMail::Envelope do
    it "defaults to the transactional stream" do
      expect(build_envelope.stream).to eq(:transactional)
    end

    it "reads the stream from the X-Sparrow-Stream header" do
      expect(build_envelope(headers: {"X-Sparrow-Stream" => "broadcast"}).stream)
        .to eq(:broadcast)
    end

    it "normalises case and surrounding space" do
      expect(build_envelope(headers: {"X-Sparrow-Stream" => "  Broadcast "}).stream)
        .to eq(:broadcast)
    end

    it "strips the control header, so it never goes out as a raw header" do
      envelope = build_envelope(headers: {"X-Sparrow-Stream" => "broadcast"})

      expect(envelope.headers.keys.map(&:downcase)).not_to include("x-sparrow-stream")
    end

    it "reports the stream in its log summary" do
      expect(build_envelope(headers: {"X-Sparrow-Stream" => "broadcast"}).log_summary)
        .to include(stream: :broadcast)
    end

    it "can read the stream off a message without building the whole envelope" do
      mail = build_mail(headers: {"X-Sparrow-Stream" => "broadcast"})

      expect(described_class.stream_from(mail)).to eq(:broadcast)
      expect(described_class.stream_from(build_mail)).to eq(:transactional)
    end
  end

  describe SparrowMail::Configuration do
    subject(:config) { described_class.new({}) }

    before do
      config.adapter = :postmark
      config.settings = {api_key: "shared-key"}
    end

    it "knows the transactional stream without being told" do
      expect(config.streams).to eq([:transactional])
    end

    it "takes per-stream settings that merge over the defaults" do
      config.stream :broadcast, settings: {message_stream: "broadcast"}

      expect(config.adapter_settings_for(:broadcast))
        .to include(api_key: "shared-key", message_stream: "broadcast")
    end

    it "lets a stream override a shared credential, for a separate account" do
      config.stream :broadcast, settings: {api_key: "bulk-key"}

      expect(config.adapter_settings_for(:broadcast)[:api_key]).to eq("bulk-key")
      expect(config.adapter_settings_for(:transactional)[:api_key]).to eq("shared-key")
    end

    # Credentials belong to the provider that issued them.
    #
    # Inheriting them across providers means a Postmark token reaching a
    # SendLayer adapter, and a stream that forgot to declare its own key
    # authenticating as something else rather than failing. A credential that
    # can be confused is one that eventually will be, and one confused quietly
    # is worse than one missing loudly.
    describe "a stream on a different provider" do
      it "inherits none of the default provider's credentials" do
        config.stream :broadcast, adapter: :mailgun, settings: {api_key: "mailgun-key"}

        settings = config.adapter_settings_for(:broadcast)

        expect(settings[:api_key]).to eq("mailgun-key")
        expect(settings.values).not_to include("shared-key")
      end

      it "inherits nothing even when it declares no settings of its own" do
        config.stream :broadcast, adapter: :mailgun

        expect(config.adapter_settings_for(:broadcast)).not_to include(api_key: "shared-key")
      end

      # Keys the other provider never reads are still credentials, and still
      # must not travel: an SES access key reaching a SendLayer adapter is
      # nonsense at best and a leak into somebody's logs at worst.
      it "leaves behind credential keys the new provider does not even use" do
        config.settings = {access_key_id: "AKIA-transactional", region: "us-east-1"}
        config.stream :broadcast, adapter: :send_layer, settings: {api_key: "sendlayer-key"}

        settings = config.adapter_settings_for(:broadcast)

        expect(settings).not_to have_key(:access_key_id)
        expect(settings).not_to have_key(:region)
      end

      # Not credentials: these describe the message and the run rather than an
      # account with anybody, so every stream needs them.
      it "still receives sandbox and default_from" do
        config.sandbox = true
        config.default_from = "Example <no-reply@example.com>"
        config.stream :broadcast, adapter: :mailgun, settings: {api_key: "mailgun-key"}

        settings = config.adapter_settings_for(:broadcast)

        expect(settings[:sandbox]).to be(true)
        expect(settings[:default_from]).to eq("Example <no-reply@example.com>")
      end

      # Naming the same adapter is not "a different provider", so the
      # convenience of changing one setting survives.
      it "still inherits when it names the same adapter explicitly" do
        config.stream :broadcast, adapter: config.adapter, settings: {message_stream: "bulk"}

        expect(config.adapter_settings_for(:broadcast))
          .to include(api_key: "shared-key", message_stream: "bulk")
      end
    end

    # The separation that matters for a provider with no stream concept of its
    # own. Bulk mail can leave through an entirely different provider.
    it "lets a stream use a different adapter entirely" do
      config.stream :broadcast, adapter: :mailgun, settings: {domain: "news.example.com"}

      expect(config.adapter_for_stream(:broadcast)).to eq(:mailgun)
      expect(config.adapter_for_stream(:transactional)).to eq(:postmark)
    end

    it "falls back to the default adapter for a stream that does not name one" do
      config.stream :broadcast, settings: {message_stream: "broadcast"}

      expect(config.adapter_for_stream(:broadcast)).to eq(:postmark)
    end

    it "lists every configured stream" do
      config.stream :broadcast, settings: {}
      config.stream :digest, settings: {}

      expect(config.streams).to contain_exactly(:transactional, :broadcast, :digest)
    end

    it "accepts a stream name as a string" do
      config.stream "broadcast", settings: {message_stream: "broadcast"}

      expect(config.streams).to include(:broadcast)
    end

    it "does not leak per-stream credentials into inspect" do
      config.stream :broadcast, settings: {api_key: "bulk-secret-key"}

      expect(config.inspect).not_to include("bulk-secret-key")
      expect(config.inspect).to include("broadcast")
    end
  end

  describe "routing a message to its stream's adapter" do
    before do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.stream :broadcast, adapter: :test, settings: {label: "bulk"}
      end
    end

    it "sends a message with no stream through the default adapter" do
      expect(SparrowMail.adapter_for(:transactional)).to be(SparrowMail.adapter)
    end

    it "builds a separate adapter instance for another stream" do
      expect(SparrowMail.adapter_for(:broadcast)).not_to be(SparrowMail.adapter_for(:transactional))
    end

    it "gives the stream's adapter the stream's settings" do
      expect(SparrowMail.adapter_for(:broadcast).settings).to include(label: "bulk")
      expect(SparrowMail.adapter_for(:transactional).settings).not_to have_key(:label)
    end

    it "memoises each stream's adapter separately" do
      expect(SparrowMail.adapter_for(:broadcast)).to be(SparrowMail.adapter_for(:broadcast))
    end

    it "rebuilds every stream's adapter after reconfiguration" do
      first = SparrowMail.adapter_for(:broadcast)
      SparrowMail.configure { |config| config.adapter = :test }

      expect(SparrowMail.adapter_for(:transactional)).not_to be(first)
    end

    it "routes deliver! by the stream named on the message" do
      SparrowMail.deliver!(build_mail(headers: {"X-Sparrow-Stream" => "broadcast"}))

      expect(SparrowMail.deliveries.last.stream).to eq(:broadcast)
    end

    it "routes deliver by the stream named on the message" do
      result = SparrowMail.deliver(build_mail(headers: {"X-Sparrow-Stream" => "broadcast"}))

      expect(result.stream).to eq(:broadcast)
    end

    it "reports the stream on the result" do
      expect(SparrowMail.deliver!(build_mail).stream).to eq(:transactional)
    end

    # Fail closed. Silently sending bulk mail down the transactional stream
    # because of a typo in a header is the exact outcome streams exist to
    # prevent, and it would not be visible until the reputation damage was done.
    it "refuses a stream nobody configured, rather than quietly using the default" do
      expect { SparrowMail.deliver!(build_mail(headers: {"X-Sparrow-Stream" => "braodcast"})) }
        .to raise_error(SparrowMail::ConfigurationError, /braodcast/)
    end

    it "names the streams that do exist when it refuses" do
      expect { SparrowMail.adapter_for(:nonsense) }
        .to raise_error(SparrowMail::ConfigurationError) { |error|
          expect(error.message).to include("transactional")
          expect(error.message).to include("broadcast")
        }
    end

    it "always accepts the transactional stream, even with nothing configured" do
      SparrowMail.configure { |config| config.adapter = :test }

      expect { SparrowMail.adapter_for(:transactional) }.not_to raise_error
    end
  end

  describe "logging" do
    let(:logger) { CapturingLogger.new }

    before do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.logger = logger
        config.stream :broadcast, settings: {}
      end
    end

    it "records which stream a message went out on" do
      SparrowMail.deliver!(build_mail(headers: {"X-Sparrow-Stream" => "broadcast"}))

      expect(logger).to have_logged("stream=broadcast")
    end
  end
end
