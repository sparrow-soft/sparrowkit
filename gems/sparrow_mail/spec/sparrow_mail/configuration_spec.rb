# frozen_string_literal: true

RSpec.describe SparrowMail::Configuration do
  describe "defaults" do
    it "has no adapter until one is chosen" do
      expect(SparrowMail.configuration.adapter).to be_nil
    end

    it "is not in sandbox mode" do
      expect(SparrowMail.configuration).not_to be_sandbox
    end

    it "has no logger, so a gem that is merely installed writes nothing" do
      expect(SparrowMail.configuration.logger).to be_nil
    end
  end

  describe "configuring in code" do
    it "takes the adapter and its settings" do
      SparrowMail.configure do |config|
        config.adapter = :postmark
        config.settings = {api_key: "pm-key"}
      end

      expect(SparrowMail.configuration.adapter).to eq(:postmark)
      expect(SparrowMail.configuration.settings).to eq(api_key: "pm-key")
    end

    it "accepts the adapter as a string and normalises it" do
      SparrowMail.configure { |config| config.adapter = "sendgrid" }

      expect(SparrowMail.configuration.adapter).to eq(:sendgrid)
    end

    it "merges sandbox into the settings handed to the adapter" do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.sandbox = true
        config.settings = {api_key: "k"}
      end

      expect(SparrowMail.configuration.adapter_settings).to include(sandbox: true, api_key: "k")
    end

    it "lets the settings win when they name sandbox explicitly" do
      SparrowMail.configure do |config|
        config.sandbox = true
        config.settings = {sandbox: false}
      end

      expect(SparrowMail.configuration.adapter_settings[:sandbox]).to be(false)
    end
  end

  describe "configuring from the environment" do
    it "reads the adapter from SPARROW_MAIL_ADAPTER" do
      config = described_class.new({"SPARROW_MAIL_ADAPTER" => "mailgun"})

      expect(config.adapter).to eq(:mailgun)
    end

    it "reads sandbox mode from SPARROW_MAIL_SANDBOX" do
      expect(described_class.new({"SPARROW_MAIL_SANDBOX" => "true"})).to be_sandbox
      expect(described_class.new({"SPARROW_MAIL_SANDBOX" => "1"})).to be_sandbox
      expect(described_class.new({"SPARROW_MAIL_SANDBOX" => "false"})).not_to be_sandbox
      expect(described_class.new({})).not_to be_sandbox
    end

    it "lets code override the environment, because an initializer is more specific" do
      config = described_class.new({"SPARROW_MAIL_ADAPTER" => "mailgun"})
      config.adapter = :postmark

      expect(config.adapter).to eq(:postmark)
    end
  end

  describe "never logging message bodies" do
    it "keeps credentials out of inspect, since settings hold API keys" do
      SparrowMail.configure do |config|
        config.adapter = :postmark
        config.settings = {api_key: "pm-secret-key"}
      end

      expect(SparrowMail.configuration.inspect).not_to include("pm-secret-key")
      expect(SparrowMail.configuration.inspect).to include("postmark")
    end
  end
end

RSpec.describe SparrowMail do
  describe ".adapter" do
    it "builds the configured adapter" do
      SparrowMail.configure do |config|
        config.adapter = :test
      end

      expect(SparrowMail.adapter).to be_a(SparrowMail::Adapters::Test)
    end

    it "memoises it, so one adapter instance serves the process" do
      SparrowMail.configure { |config| config.adapter = :test }

      expect(SparrowMail.adapter).to be(SparrowMail.adapter)
    end

    it "rebuilds after reconfiguration" do
      SparrowMail.configure { |config| config.adapter = :test }
      first = SparrowMail.adapter
      SparrowMail.configure { |config| config.adapter = :test }

      expect(SparrowMail.adapter).not_to be(first)
    end

    it "explains itself when no adapter is configured" do
      expect { SparrowMail.adapter }
        .to raise_error(SparrowMail::ConfigurationError, /no adapter configured/i)
    end

    it "explains itself when the adapter name is unknown, and lists the real ones" do
      SparrowMail.configure { |config| config.adapter = :carrier_pigeon }

      expect { SparrowMail.adapter }
        .to raise_error(SparrowMail::ConfigurationError) { |error|
          expect(error.message).to include("carrier_pigeon")
          expect(error.message).to include("sendlayer")
          expect(error.message).to include("smtp")
        }
    end
  end

  describe ".register_adapter" do
    it "accepts a third-party adapter under a new name" do
      SparrowMail.register_adapter(:counting, FakeAdapters::Counting)
      SparrowMail.configure { |config| config.adapter = :counting }

      expect(SparrowMail.adapter).to be_a(FakeAdapters::Counting)
    ensure
      SparrowMail.registry.delete(:counting)
    end
  end

  describe ".deliver!" do
    it "delivers through the configured adapter" do
      SparrowMail.configure { |config| config.adapter = :test }

      result = SparrowMail.deliver!(build_mail)

      expect(result.adapter).to eq(:test)
      expect(SparrowMail.deliveries.size).to eq(1)
    end

    it "applies the configured sandbox mode" do
      SparrowMail.configure do |config|
        config.adapter = :test
        config.sandbox = true
      end

      expect(SparrowMail.deliver!(build_mail)).to be_sandbox
    end
  end

  describe ".deliveries" do
    it "can be cleared" do
      SparrowMail.configure { |config| config.adapter = :test }
      SparrowMail.deliver!(build_mail)
      SparrowMail.deliveries.clear

      expect(SparrowMail.deliveries).to be_empty
    end
  end
end
