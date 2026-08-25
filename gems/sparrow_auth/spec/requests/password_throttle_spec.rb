# frozen_string_literal: true

require "rails_helper"
require "uri"

# Password guessing, throttled.
#
# The sign-in method with the weakest secret had no limit while the strongest had four.
# Fifty wrong passwords in a row were all answered normally, and the correct one
# still worked immediately afterwards.
#
# What this throttles is the password *path*, not the account. That distinction
# is the whole reason an expiring lockout is acceptable: somebody being worked
# through a word list can still sign in with a code or a passkey while it lasts,
# so the denial of service an attacker can inflict costs their victim nothing
# they cannot route around.
RSpec.describe "guessing a password", type: :request do
  let(:password) { "correct horse battery staple" }
  let(:email) { "target@example.org" }

  def register_and_verify(address = email)
    post "/auth/create-account", params: {
      login: address, password: password, "password-confirm": password
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
    post "/auth/logout"
    SparrowAuth::Account.find_by_email(address)
  end

  def guess(times, address: email)
    times.times { |i| post "/auth/login", params: {login: address, password: "guess-#{i}"} }
  end

  def sessions_for(account)
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
      "WHERE account_id = #{account.id.to_i}"
    )
  end

  let(:budget) { SparrowAuth::RateLimiter::LOGIN_PER_EMAIL.limit }

  describe "the limit" do
    it "stops accepting the correct password once the budget is spent" do
      account = register_and_verify
      guess(budget)

      post "/auth/login", params: {login: email, password: password}

      expect(sessions_for(account)).to eq(0)
    end

    it "still accepts it one attempt short of the budget" do
      account = register_and_verify
      guess(budget - 1)

      post "/auth/login", params: {login: email, password: password}

      expect(sessions_for(account)).to eq(1)
    end

    # Otherwise using your own account correctly is what locks you out of it.
    it "spends nothing on a successful sign-in" do
      register_and_verify

      expect {
        post "/auth/login", params: {login: email, password: password}
      }.not_to change { SparrowAuth::AuthEvent.where(bucket: "login:email").count }
    end

    # A refused attempt that were recorded would let somebody at the cap hold
    # themselves there indefinitely by continuing to try.
    it "does not extend the window by continuing to guess" do
      register_and_verify
      guess(budget)
      recorded = SparrowAuth::AuthEvent.where(bucket: "login:email").count

      guess(5)

      expect(SparrowAuth::AuthEvent.where(bucket: "login:email").count).to eq(recorded)
    end

    # Keyed on the stored address, so a fresh allowance cannot be bought by
    # holding down shift.
    it "cannot be reset by changing the capitalisation of the address" do
      account = register_and_verify
      guess(budget)

      post "/auth/login", params: {login: "TARGET@Example.ORG", password: password}

      expect(sessions_for(account)).to eq(0)
    end
  end

  describe "what the throttled response says" do
    # A throttled attempt that announced itself would answer "does this address
    # have an account here" on every throttled account, which is the oracle this
    # engine spent a commit closing.
    it "is indistinguishable from an ordinary wrong password" do
      register_and_verify
      register_and_verify("other@example.org")
      get "/auth/login"

      post "/auth/login", params: {login: "other@example.org", password: "wrong"}
      ordinary = [response.status, normalised(response.body, "other@example.org")]

      guess(budget)
      post "/auth/login", params: {login: email, password: password}
      throttled = [response.status, normalised(response.body, email)]

      expect(throttled).to eq(ordinary)
    end

    def normalised(body, address)
      body.gsub(address, "ADDRESS").gsub(/[A-Za-z0-9+\/=_-]{40,}/, "TOKEN")
    end
  end

  # The point of throttling the path rather than the account.
  describe "the other sign-in methods, while the password path is throttled" do
    # Driven through SparrowAuth::SignIn, which is what the application's sign-in
    # screen calls: the budgets are keyed per bucket, so spending the password
    # budget must leave the code budget untouched.
    it "still signs in with an emailed code" do
      account = register_and_verify
      guess(budget)

      request_id = SparrowAuth::SignIn.request(email: email, ip: "203.0.113.66")
      code = SparrowMail.deliveries.last.text_body[/\b\d{6}\b/]

      redeemed = SparrowAuth::SignIn.redeem(
        code: code, request_id: request_id, ip: "203.0.113.66"
      )

      expect(redeemed.id).to eq(account.id)
    end

    it "still signs in with a passkey" do
      account = register_and_verify
      post "/auth/login", params: {login: email, password: password}
      enroll_passkey
      post "/auth/logout"
      guess(budget)

      sign_in_with_passkey

      expect(sessions_for(account)).to eq(1)
    end
  end

  describe "telling the owner" do
    def notices
      SparrowMail.deliveries.select { |mail|
        mail.subject == "Somebody is trying to sign in to your account"
      }
    end

    it "emails them once the guessing is throttled" do
      register_and_verify
      guess(budget + 1)

      expect(notices.size).to eq(1)
    end

    it "does not email on ordinary wrong passwords" do
      register_and_verify
      guess(budget - 1)

      expect(notices).to be_empty
    end

    # Otherwise the notification is the attack: an attacker who can trigger it
    # per attempt can mail somebody continuously.
    it "sends one message however many refused attempts follow" do
      register_and_verify
      guess(budget + 20)

      expect(notices.size).to eq(1)
    end

    it "points at adding a passkey, which is the way out" do
      register_and_verify
      guess(budget + 1)

      expect(notices.first.text_body).to include("webauthn-setup")
    end
  end
end
