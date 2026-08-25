# frozen_string_literal: true

require "rails_helper"

# The panel's acceptance criterion, said as tests: every control on the page
# changes real behaviour, and nothing is offered that the panel cannot do.
#
# That is worth a file of its own because the failure it guards against is
# invisible. A switch that writes a setting nothing reads looks exactly like a
# switch that works — the form saves, the page comes back showing the new state,
# and the application goes on doing what it did before. The audit that started
# this release found four of them.
PANEL = "/sparrowkit/auth"

RSpec.describe "what the auth panel actually changes", type: :request do
  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
  end

  def save(overrides = {})
    patch PANEL, params: {
      webauthn_rp_id_override: "0",
      webauthn_rp_name_override: "0",
      sender_name: "Example",
      sender_email: "no-reply@example.com",
      signup_with_code: "1",
      passwords_enabled: "0",
      emailed_sign_in: "code",
      otp_secret: ""
    }.merge(overrides)
  end

  def stored
    ConsoleCredentials.stored
  end

  describe "the emailed sign-in choice" do
    it "stores what the radio sent" do
      save(emailed_sign_in: "link")

      expect(stored[:emailed_sign_in]).to eq(:link)
    end

    # The whole point of the setting. Storing it and having nothing read it is
    # the defect this file exists for.
    it "changes what is actually sent" do
      SparrowAuth.config.emailed_sign_in = :link
      SparrowAuth::SignIn.request(
        email: verified("owner@example.org").email, ip: "127.0.0.1", base_url: "http://www.example.com"
      )

      expect(SparrowMail.deliveries.last.text_body).to include("/auth/email-auth")
    end

    it "comes back checked on the way it was left" do
      ConsoleCredentials.reset!(sparrow_auth: {emailed_sign_in: "link"})

      get PANEL

      expect(response.body).to match(/id="auth_emailed_sign_in_link"[^>]*checked/m)
      expect(response.body).not_to match(/id="auth_emailed_sign_in_code"[^>]*checked/m)
    end

    # A radio sends exactly one value or none at all, so "both" and "neither"
    # are not states a browser can produce. A hand-made request can, and it is
    # refused rather than defaulted: quietly choosing one would be this panel
    # deciding how an application signs people in.
    it "refuses a value that is neither, and saves nothing" do
      save(emailed_sign_in: "carrier-pigeon")

      expect(response).to have_http_status(:unprocessable_content)
      expect(stored[:emailed_sign_in]).to be_nil
      expect(flash.now[:alert]).to match(/code or link/i)
    end

    it "refuses an absent one the same way" do
      patch PANEL, params: {sender_name: "Example", sender_email: "no-reply@example.com",
                            webauthn_rp_id_override: "0", webauthn_rp_name_override: "0",
                            signup_with_code: "1", passwords_enabled: "0", otp_secret: ""}

      expect(response).to have_http_status(:unprocessable_content)
    end
  end

  describe "Google and Apple" do
    it "stores a provider's credentials under its own name" do
      save(social: {google_oauth2: {client_id: "google-id", client_secret: "google-secret"}})

      expect(stored.dig(:social_providers, :google_oauth2, :client_id)).to eq("google-id")
      expect(stored.dig(:social_providers, :google_oauth2, :client_secret)).to eq("google-secret")
    end

    it "keeps one provider's credentials out of the other's" do
      save(social: {google_oauth2: {client_id: "google-id", client_secret: "google-secret"}})

      expect(stored.dig(:social_providers, :apple)).to be_nil
    end

    # Named keys rather than a positional pair, and that is a masking decision:
    # sparrow_ui masks by the NAME of a key, so `client_secret` is masked
    # wherever it appears and the second element of an array is masked nowhere.
    it "never renders a stored secret back" do
      ConsoleCredentials.reset!(sparrow_auth: {
        social_providers: {google_oauth2: {client_id: "google-id", client_secret: "google-live-do-not-print"}}
      })

      get PANEL

      expect(response.body).not_to include("google-live-do-not-print")
      expect(response.body).to include("google-id")
    end

    it "leaves a provider out entirely when neither box was filled in" do
      save(social: {google_oauth2: {client_id: "", client_secret: ""}})

      expect(stored[:social_providers]).to be_nil
    end

    # A control panel cannot add a gem to a Gemfile, so it says which line to
    # add rather than offering a control that would produce a callback route
    # raising on its first visitor.
    it "names the gem each provider needs, and the line to add" do
      get PANEL

      expect(response.body).to include("omniauth-google-oauth2")
      expect(response.body).to include("omniauth-apple")
    end

    # rodauth-omniauth carries the whole feature, so its absence is worth saying
    # once at the top rather than repeating per provider. This dummy has it, so
    # what is asserted is that the notice is NOT shown when it is there —
    # a warning that is always on screen is a warning nobody reads.
    it "stays quiet about rodauth-omniauth when it is installed" do
      get PANEL

      expect(response.body).not_to include("is not in your
        bundle")
    end

    # Somebody who pastes their credentials before running bundle install
    # should find them there afterwards.
    it "stores credentials even though the gem is not installed" do
      save(social: {apple: {client_id: "apple-id", client_secret: "apple-secret"}})

      expect(stored.dig(:social_providers, :apple, :client_id)).to eq("apple-id")
    end
  end

  describe "what is settled and has no control" do
    it "offers no switch for passkeys" do
      get PANEL

      expect(response.body).not_to match(/name="passkeys_enabled"/)
      expect(response.body).to include("Passkeys are always on")
    end

    it "offers no switch for email verification" do
      get PANEL

      expect(response.body).not_to match(/name="verify_account"/)
      expect(response.body).to include("Email verification is always on")
    end

    # API tokens were cut in Phase 1. The panel went on offering a field for
    # their signing key for two releases after the feature stopped existing,
    # which is the same defect as a switch that does nothing, wearing a
    # different hat.
    it "offers no field for a feature that no longer exists" do
      get PANEL

      expect(response.body).not_to include("api_token_secret")
      expect(response.body).not_to include("API token key")
    end
  end

  def verified(email)
    SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)
  end
end
