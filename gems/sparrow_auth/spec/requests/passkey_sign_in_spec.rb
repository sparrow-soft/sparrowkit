# frozen_string_literal: true

require "rails_helper"

# The sign-in screen is the application's, so what the engine owns here is the
# script behind rodauth.render("webauthn-autofill"), where a failed passkey
# lands, and the one-time offer of a passkey after an emailed code.
RSpec.describe "passkey sign-in", type: :request do
  let(:email) { "newcomer@example.org" }
  let(:password) { "correct horse battery staple" }

  def signed_in?
    get "/account-settings"
    response.status == 200
  rescue SparrowAuth::UnverifiedAccount
    false
  end

  describe "the script" do
    it "replaces Rodauth's autofill script with one that also drives a button" do
      get "/auth/webauthn-autofill-js"

      expect(response.media_type).to eq("text/javascript")
      expect(response.body).to include('mediation: "conditional"', "data-sparrow-auth-passkey", "AbortController")
    end
  end

  describe "a passkey that does not work" do
    def refused_passkey(referer: nil)
      get "/auth/login"
      challenge = field_value(response.body, "webauthn_auth_challenge")
      hmac = field_value(response.body, "webauthn_auth_challenge_hmac")

      # A credential the authenticator holds and this application never saw.
      authenticator.create(challenge: SecureRandom.hex(16))
      assertion = authenticator.get(challenge: challenge, user_verified: true)
      post "/auth/webauthn-login", params: {
        webauthn_auth: assertion.to_json,
        webauthn_auth_challenge: challenge,
        webauthn_auth_challenge_hmac: hmac
      }, headers: (referer ? {"Referer" => referer} : {})
    end

    it "goes back to the application's sign-in screen, with a sentence that says so" do
      refused_passkey

      expect(response).to redirect_to(SparrowAuth.config.sign_in_path)
      expect(flash[:alert]).to eq("That passkey didn’t work. Try again, or use your email address.")
    end

    # An application with two sign-in screens.
    it "goes back to the sign-in screen it came from" do
      refused_passkey(referer: "http://www.example.com/trade/sign-in")

      expect(response).to redirect_to("/trade/sign-in")
    end

    it "never goes back to another site, or to a Rodauth page" do
      refused_passkey(referer: "https://evil.example/sign-in")
      expect(response).to redirect_to(SparrowAuth.config.sign_in_path)

      refused_passkey(referer: "http://www.example.com/auth/login")
      expect(response).to redirect_to(SparrowAuth.config.sign_in_path)
    end
  end

  describe "after adding one" do
    def register_and_sign_in
      post "/auth/create-account", params: {login: email, password: password, "password-confirm": password}
      url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
      key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
      get "/auth/verify-account", params: {key: key}
      post "/auth/verify-account", params: {key: key}
    end

    def enroll_from(path)
      get "/auth/webauthn-setup", params: {return_to: path}
      challenge = field_value(response.body, "webauthn_setup_challenge")
      hmac = field_value(response.body, "webauthn_setup_challenge_hmac")
      post "/auth/webauthn-setup", params: {
        webauthn_setup: authenticator.create(challenge: challenge).to_json,
        webauthn_setup_challenge: challenge, webauthn_setup_challenge_hmac: hmac, password: password
      }
    end

    it "goes back to the page that asked, with the notice" do
      register_and_sign_in
      enroll_from("/account-settings")

      expect(response).to redirect_to("/account-settings")
      expect(flash[:notice]).to start_with("Passkey added.")
    end

    # Browsers read a backslash as a slash and drop a tab, so "/\\evil.example"
    # and "/\t/evil.example" are "//evil.example": another site.
    ["//evil.example/steal", "/\\evil.example/steal", "/\\/evil.example",
      "https://evil.example/", "/\t/evil.example"].each do |target|
      it "will not go to #{target.inspect}" do
        register_and_sign_in
        enroll_from(target)

        expect(response.location).not_to include("evil.example")
      end
    end
  end

  describe "where a passkey sign-in lands" do
    def enrolled_and_signed_out
      post "/auth/create-account", params: {login: email, password: password, "password-confirm": password}
      url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
      key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
      get "/auth/verify-account", params: {key: key}
      post "/auth/verify-account", params: {key: key}
      enroll_passkey
      post "/auth/logout"
    end

    def passkey_sign_in_from(page)
      get page
      challenge = field_value(response.body, "webauthn_auth_challenge")
      hmac = field_value(response.body, "webauthn_auth_challenge_hmac")
      post "/auth/webauthn-login", params: {
        webauthn_auth: authenticator.get(challenge: challenge, user_verified: true).to_json,
        webauthn_auth_challenge: challenge,
        webauthn_auth_challenge_hmac: hmac
      }
    end

    it "lands where the sign-in screen said" do
      enrolled_and_signed_out
      passkey_sign_in_from("/trade/sign-in")

      expect(response).to redirect_to("/account-settings")
      expect(signed_in?).to be(true)
    end

    it "lands on / when the screen said nothing" do
      enrolled_and_signed_out
      passkey_sign_in_from("/auth/login")

      expect(response).to redirect_to("/")
    end

    it "lands on / rather than on another site" do
      enrolled_and_signed_out
      passkey_sign_in_from("/trade/sign-in?land=%2F%5Cevil.example")

      expect(response).to redirect_to("/")
    end
  end

  describe "offering a passkey" do
    let(:account) { SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED) }

    it "is due for an account with no passkey that has not said no" do
      expect(account.passkey_prompt_due?).to be(true)
    end

    it "is not due once the account has said not now" do
      account.dismiss_passkey_prompt!

      expect(account.reload.passkey_prompt_due?).to be(false)
    end

    it "is not due for an account with a passkey" do
      post "/auth/create-account", params: {login: email, password: password, "password-confirm": password}
      url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
      key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
      get "/auth/verify-account", params: {key: key}
      post "/auth/verify-account", params: {key: key}
      enroll_passkey

      expect(flash[:notice]).to eq("Passkey added. Next time, sign in with it instead of a code.")
      expect(SparrowAuth::Account.find_by_email(email).passkey_prompt_due?).to be(false)
    end
  end
end
