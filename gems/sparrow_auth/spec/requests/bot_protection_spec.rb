# frozen_string_literal: true

require "rails_helper"

# Every route that sends mail to an address somebody typed, and what stands in
# front of it: Turnstile, said out loud because it is about the browser, and a
# Tor exit, refused in silence because the answer must be the one every address
# gets.
#
# The application's own sign-in screen calls SparrowAuth::Turnstile.passed? and
# SignIn.request itself. Rodauth's create-account and resend pages run as
# middleware, above any controller of the application's, so the engine checks
# them -- and those are what this file drives.
RSpec.describe "bot protection", type: :request do
  let(:email) { "newcomer@example.org" }
  let(:password) { "correct horse battery staple" }

  def create_account(token: nil, env: {})
    params = {login: email, password: password, "password-confirm": password}
    params[SparrowAuth::Turnstile::TOKEN_FIELD] = token if token
    post "/auth/create-account", params: params, env: env
  end

  def resend(token: nil, env: {})
    params = {login: email}
    params[SparrowAuth::Turnstile::TOKEN_FIELD] = token if token
    post "/auth/verify-account-resend", params: params, env: env
  end

  def tor
    {"REMOTE_ADDR" => BotProtectionHelpers::TOR_EXIT}
  end

  describe "creating an account" do
    it "draws no widget while Turnstile is off" do
      get "/auth/create-account"

      expect(response.body).not_to include("data-sparrow-auth-turnstile")
    end

    it "draws the widget inside the form while Turnstile is on" do
      with_turnstile do
        get "/auth/create-account"

        expect(response.body).to match(/<form[^>]*>.*data-sparrow-auth-turnstile.*data-action="create_account".*<\/form>/m)
      end
    end

    it "refuses a submission with no token, out loud, and sends nothing" do
      with_turnstile do |calls|
        expect { create_account }.not_to change(SparrowAuth::Account, :count)

        expect(response).to redirect_to("/auth/create-account")
        expect(flash[:alert]).to eq(SparrowAuth::Turnstile::REFUSAL_MESSAGE)
        expect(SparrowMail.deliveries).to be_empty
        expect(calls).to be_empty
      end
    end

    it "lets a passing token through" do
      with_turnstile(answer: turnstile_pass(action: "create_account")) do
        expect { create_account(token: BotProtectionHelpers::TURNSTILE_TOKEN) }
          .to change(SparrowAuth::Account, :count).by(1)
      end
    end

    it "refuses a token solved on a different form" do
      with_turnstile(answer: turnstile_pass(action: "login")) do
        expect { create_account(token: BotProtectionHelpers::TURNSTILE_TOKEN) }
          .not_to change(SparrowAuth::Account, :count)
      end
    end

    it "answers a Tor exit as it answers anybody, with no account and no mail" do
      create_account
      expected = [response.status, response.location, flash[:notice]]
      SparrowAuth::Account.delete_all
      SparrowMail.deliveries.clear
      list_tor_exit

      expect { create_account(env: tor) }.not_to change(SparrowAuth::Account, :count)
      expect([response.status, response.location, flash[:notice]]).to eq(expected)
      expect(SparrowMail.deliveries).to be_empty
    end
  end

  describe "resending the confirmation email" do
    before do
      create_account
      SparrowMail.deliveries.clear
      # Rodauth will not resend within five minutes of the first.
      travel 10.minutes
    end

    it "draws the widget while Turnstile is on" do
      with_turnstile do
        get "/auth/verify-account-resend"

        expect(response.body).to include('data-action="resend_confirmation"')
      end
    end

    it "refuses a submission with no token, and sends nothing" do
      with_turnstile do
        resend

        expect(flash[:alert]).to eq(SparrowAuth::Turnstile::REFUSAL_MESSAGE)
        expect(SparrowMail.deliveries).to be_empty
      end
    end

    it "sends nothing to a Tor exit, and says what it says to everybody" do
      list_tor_exit
      resend(env: tor)

      expect(flash[:notice]).to eq(SparrowAuth::RodauthMain::RESEND_NOTICE)
      expect(SparrowMail.deliveries).to be_empty
    end

    it "still resends for everybody else" do
      resend

      expect(SparrowMail.deliveries.size).to eq(1)
    end
  end

  # SignIn reaches Rodauth's email-auth-request as an internal request. Over
  # HTTP it sent a link to any registered address with none of SignIn's rate
  # limits, and answered an unknown address with a different flash.
  describe "Rodauth's own sign-in link route" do
    it "is not there" do
      SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)

      # Rodauth steps aside and the request falls through to the application's
      # router, which has no such route: a 404 in production.
      expect { post "/auth/email-auth-request", params: {login: email} }
        .to raise_error(ActionController::RoutingError)
      expect(SparrowMail.deliveries).to be_empty
    end
  end

  describe "the Turnstile script" do
    it "is served beside Rodauth's own" do
      get SparrowAuth::Turnstile.script_path

      expect(response).to have_http_status(:ok)
      expect(response.media_type).to eq("text/javascript")
      expect(response.body).to include("data-sparrow-auth-turnstile", "challenges.cloudflare.com")
    end
  end
end
