# frozen_string_literal: true

require "rails_helper"
require "uri"

# A closed account is refused by every sign-in method.
#
# Closing is the one state that has to hold against credentials that are still
# perfectly valid: the password still matches, the passkey still signs, the
# address still receives mail. Nothing about the credential changed — only the
# account's standing did — so each sign-in method has to check that separately, and each
# is a separate place to forget.
#
# The engine did all of this correctly and none of it was tested.
RSpec.describe "a closed account", type: :request do
  let(:password) { "correct horse battery staple" }
  let(:email) { "shut@example.org" }

  def register_and_verify
    post "/auth/create-account", params: {
      login: email, password: password, "password-confirm": password
    }
    url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
    key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
    get url
    # GET first, the way somebody clicking the emailed link does. Rodauth 2.47
    # takes the key from the session that GET establishes rather than from the
    # POST body, so a POST on its own is refused -- and a POST on its own is not
    # a thing a browser ever does.
    get "/auth/verify-account", params: {key: key}
    post "/auth/verify-account", params: {key: key}
    SparrowAuth::Account.find_by_email(email)
  end

  def close!(account)
    SparrowAuth::Account.where(id: account.id)
      .update_all(status_id: SparrowAuth::Account::CLOSED)
    account.reload
  end

  def sessions_for(account)
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
      "WHERE account_id = #{account.id.to_i}"
    )
  end

  describe "the password sign-in method" do
    it "refuses the correct password" do
      account = register_and_verify
      post "/auth/logout"
      close!(account)

      post "/auth/login", params: {login: email, password: password}

      expect(sessions_for(account)).to eq(0)
    end

    # Uniform, like every other sign-in failure. "This account is closed" is
    # still an answer to "does this address have an account here".
    it "answers exactly as it does for an address with no account" do
      account = register_and_verify
      post "/auth/logout"
      close!(account)

      # Signing out leaves a flash pending, which would otherwise be rendered
      # into whichever of the two responses came first and read as a difference
      # between them.
      get "/auth/login"

      post "/auth/login", params: {login: "stranger@example.org", password: password}
      baseline = [response.status, response.body.gsub("stranger@example.org", "X")
        .gsub(/[A-Za-z0-9+\/=_-]{40,}/, "T")]

      post "/auth/login", params: {login: email, password: password}
      closed = [response.status, response.body.gsub(email, "X")
        .gsub(/[A-Za-z0-9+\/=_-]{40,}/, "T")]

      expect(closed).to eq(baseline)
    end
  end

  # Driven through SparrowAuth::SignIn rather than over HTTP: the sign-in screen
  # is the buyer's now, and every decision below is the service's.
  describe "the emailed-code sign-in method" do
    let(:ip) { "203.0.113.44" }

    def request_code
      SparrowAuth::SignIn.request(email: email, ip: ip)
    end

    it "issues no code" do
      account = register_and_verify
      close!(account)
      SparrowMail.deliveries.clear

      request_code

      expect(SparrowAuth::OneTimeCode.where(email: email)).to be_empty
    end

    it "does not sign them in" do
      account = register_and_verify
      post "/auth/logout"
      close!(account)

      request_id = request_code
      code = SparrowMail.deliveries.last.text_body[/\b\d{6}\b/]

      expect(code).to be_nil
      expect {
        SparrowAuth::SignIn.redeem(code: "000000", request_id: request_id, ip: ip)
      }.to raise_error(SparrowAuth::InvalidCode)
      expect(sessions_for(account)).to eq(0)
    end

    # The account exists, so signup must not treat it as a free address and
    # quietly make a second one.
    it "does not create a replacement account" do
      account = register_and_verify
      close!(account)

      expect { request_code }.not_to change(SparrowAuth::Account, :count)
    end

    # A closed account holding a code issued before it closed. The code is
    # genuine and unspent; only the account's standing refuses it, which is the
    # line in #redeem this is here to keep.
    it "refuses a code issued while the account was still open" do
      account = register_and_verify
      post "/auth/logout"
      request_id = request_code
      code = SparrowMail.deliveries.last.text_body[/\b\d{6}\b/]
      expect(code).to be_present

      close!(account)

      expect {
        SparrowAuth::SignIn.redeem(code: code, request_id: request_id, ip: ip)
      }.to raise_error(SparrowAuth::InvalidCode)
      expect(sessions_for(account)).to eq(0)
    end
  end

  describe "the passkey sign-in method" do
    # The sharpest of the three. The credential is untouched by closing the
    # account — it still exists on the device and still produces a valid
    # signature — so nothing but an explicit check stops it working.
    it "refuses a passkey that still signs correctly" do
      account = register_and_verify
      enroll_passkey
      post "/auth/logout"
      close!(account)

      sign_in_with_passkey

      expect(sessions_for(account)).to eq(0)
    end
  end

  describe "what a closed account may reach" do
    # This asked that a closed account resolved no access even where it held an
    # explicit Grant. Those are gone with the policy object they served, so the
    # question is now the one the engine actually answers: a closed account
    # cannot be signed in, and everything downstream reads the account off the
    # session. The membership row survives being closed, deliberately — closing
    # an account is not a way to quietly remove somebody from an organization —
    # and it reaches nothing, because nobody can act as them.
    it "keeps its memberships and can act through none of them" do
      account = register_and_verify
      founder = SparrowAuth::Account.create!(
        email: "founder@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      organization = SparrowAuth::Organization.create_with_owner!(account: founder, name: "Acme")
      organization.memberships.create!(account: account, role: :admin)
      post "/auth/logout"
      close!(account)

      expect(account.reload.membership_in(organization).role).to eq("admin")

      post "/auth/login", params: {login: email, password: password}

      expect(sessions_for(account)).to eq(0)
    end

    it "cannot accept an invitation issued to its address" do
      account = register_and_verify
      inviter = SparrowAuth::Account.create!(
        email: "inviter@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      _invitation, token = SparrowAuth::Invitation.invite!(
        email: email, invited_by: inviter,
        url_builder: ->(t) { "http://example.com/auth/invitations/#{t}" }
      )
      close!(account)

      expect {
        SparrowAuth::Invitation.redeem!(token: token, account: account)
      }.to raise_error(SparrowAuth::AccessError)
    end
  end
end
