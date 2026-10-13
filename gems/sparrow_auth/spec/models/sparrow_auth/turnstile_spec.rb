# frozen_string_literal: true

require "rails_helper"

RSpec.describe SparrowAuth::Turnstile do
  let(:host) { "www.example.com" }

  def verify(token = BotProtectionHelpers::TURNSTILE_TOKEN, action: "login", hostname: host)
    described_class.verify(token: token, action: action, hostname: hostname, remote_ip: "198.51.100.4")
  end

  describe "switching on" do
    it "is off until both keys are set" do
      SparrowAuth.config.turnstile_site_key = "site"
      expect(described_class).not_to be_enabled

      SparrowAuth.config.turnstile_secret_key = "secret"
      expect(described_class).to be_enabled
    ensure
      SparrowAuth.config.turnstile_site_key = nil
      SparrowAuth.config.turnstile_secret_key = nil
    end

    it "draws nothing while off, so a form can render the widget unconditionally" do
      expect(described_class.widget(action: "login")).to eq("")
    end

    it "draws the widget and its script while on" do
      with_turnstile do
        html = described_class.widget(action: "login")

        expect(html).to include('data-sitekey="test-site-key"', 'data-action="login"')
        expect(html).to include(%(src="#{SparrowAuth.config.path_prefix}/turnstile-js"))
        expect(html).to be_html_safe
      end
    end

    it "passes every request while off, without asking Cloudflare" do
      expect(described_class).not_to receive(:siteverify)

      request = ActionDispatch::TestRequest.create
      expect(described_class.passed?(request, action: "login")).to be(true)
    end
  end

  describe "verifying" do
    it "passes a token Cloudflare vouches for, for this action and host" do
      with_turnstile(answer: turnstile_pass(action: "login")) do |calls|
        expect(verify).to be(true)
        expect(calls.first).to include(secret: "test-secret-key", response: BotProtectionHelpers::TURNSTILE_TOKEN,
          remoteip: "198.51.100.4")
      end
    end

    it "refuses what Cloudflare refuses" do
      with_turnstile(answer: {"success" => false, "error-codes" => ["invalid-input-response"]}) do
        expect(verify).to be(false)
      end
    end

    # A token solved on the sign-up form is no good on the sign-in form.
    it "refuses a token solved for a different action" do
      with_turnstile(answer: turnstile_pass(action: "signup")) do
        expect(verify(action: "login")).to be(false)
      end
    end

    # One widget can be registered for several domains.
    it "refuses a token solved on a different host" do
      with_turnstile(answer: turnstile_pass(action: "login", hostname: "elsewhere.example")) do
        expect(verify).to be(false)
      end
    end

    it "refuses a missing, empty, oversized or non-string token without asking Cloudflare" do
      with_turnstile(answer: turnstile_pass(action: "login")) do |calls|
        [nil, "", "x" * 2049, ["token"], {"a" => "b"}].each do |token|
          expect(verify(token)).to be(false)
        end
        expect(calls).to be_empty
      end
    end

    it "fails closed when Cloudflare cannot be reached" do
      with_turnstile do
        allow(SparrowAuth::Turnstile).to receive(:siteverify).and_raise(Net::OpenTimeout)

        expect(verify).to be(false)
      end
    end
  end

  # Cloudflare was seen accepting one production token three times in three
  # minutes, so a token is claimed here before Cloudflare is asked.
  describe "single use" do
    it "passes a token once" do
      with_turnstile(answer: turnstile_pass(action: "login")) do |calls|
        expect(verify).to be(true)
        expect(verify).to be(false)
        expect(verify("a-different-token")).to be(true)
        expect(calls.size).to eq(2)
      end
    end

    it "does not let a token Cloudflare refused be tried again" do
      with_turnstile(answer: {"success" => false}) do |calls|
        verify
        verify

        expect(calls.size).to eq(1)
      end
    end

    it "keeps only a digest of the token" do
      with_turnstile(answer: turnstile_pass(action: "login")) do
        verify

        keys = Rails.cache.instance_variable_get(:@data).keys
        expect(keys.join).not_to include(BotProtectionHelpers::TURNSTILE_TOKEN)
      end
    end

    # A cache outage must not stop everybody signing in.
    it "falls back to Cloudflare's own check when the cache cannot answer" do
      with_turnstile(answer: turnstile_pass(action: "login")) do
        allow(Rails.cache).to receive(:write).and_return(nil)
        expect(verify).to be(true)

        allow(Rails.cache).to receive(:write).and_raise(Errno::ECONNREFUSED)
        expect(verify("another")).to be(true)
      end
    end
  end
end
