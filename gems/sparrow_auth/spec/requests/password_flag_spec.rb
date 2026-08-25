# frozen_string_literal: true

require "rails_helper"
require "uri"

# The password sign-in method, in both positions.
#
# A flag proven in one position is not proven. The engine's default is off, and
# the rest of this suite turns it on because a password is the cheapest way to
# get an account signed in before testing something else — so the off case has
# to be exercised somewhere deliberately, and this is where.
RSpec.describe "passwords as a flag", type: :request do
  let(:password) { "correct horse battery staple" }
  let(:email) { "person@example.org" }

  # The sign-in screen is the application's, so the emailed-code flow is driven
  # through the service the generated screen calls.
  def request_code(address = email)
    SparrowAuth::SignIn.request(email: address, ip: "203.0.113.51")
  end

  def redeem(request_id)
    SparrowAuth::SignIn.redeem(
      code: SparrowMail.deliveries.last.text_body[/\b\d{6}\b/],
      request_id: request_id, ip: "203.0.113.51"
    )
  end

  # Registering and verifying with no password at all, which is the road in a
  # host gets when passwords are off: Rodauth asks for no password, and
  # verifying the address signs the account in.
  def register_and_verify_without_a_password
    post "/auth/create-account", params: {login: email}
    url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
    key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
    # GET first, the way somebody clicking the emailed link does. Rodauth 2.47
    # takes the key from the session that GET establishes rather than from the
    # POST body, so a POST on its own is refused -- and a POST on its own is not
    # a thing a browser ever does.
    get "/auth/verify-account", params: {key: key}
    post "/auth/verify-account", params: {key: key}
  end

  def password_fields_in(body)
    body.scan(/<input\b[^>]*\btype="password"[^>]*>/)
  end

  def sessions_for(address = email)
    account = SparrowAuth::Account.find_by_email(address)
    return 0 if account.nil?

    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
      "WHERE account_id = #{account.id.to_i}"
    )
  end

  describe "off, which is the default" do
    before { SparrowAuth.config.passwords_enabled = false }

    it "is the default rather than something a host must choose" do
      SparrowAuth.reset!

      expect(SparrowAuth.config.passwords_enabled).to be(false)
    end

    it "refuses a password that would otherwise be correct" do
      # Created while passwords were on, so the hash genuinely exists and
      # genuinely matches. Only the flag stands between it and a session.
      SparrowAuth.config.passwords_enabled = true
      post "/auth/create-account", params: {
        login: email, password: password, "password-confirm": password
      }
      SparrowAuth::Account.where(email: email)
        .update_all(status_id: SparrowAuth::Account::VERIFIED)
      SparrowAuth.config.passwords_enabled = false

      post "/auth/login", params: {login: email, password: password}

      expect(sessions_for).to eq(0)
    end

    it "refuses it the same way it refuses a wrong one" do
      post "/auth/login", params: {login: "nobody@example.org", password: "wrong"}
      unknown = [response.status, response.body.gsub("nobody@example.org", "X")
        .gsub(/[A-Za-z0-9+\/=_-]{40,}/, "T")]

      post "/auth/login", params: {login: email, password: password}
      refused = [response.status, response.body.gsub(email, "X")
        .gsub(/[A-Za-z0-9+\/=_-]{40,}/, "T")]

      expect(refused).to eq(unknown)
    end

    it "creates accounts with no password when one is offered anyway" do
      post "/auth/create-account", params: {
        login: email, password: password, "password-confirm": password
      }

      account = SparrowAuth::Account.find_by_email(email)
      hashes = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM sparrow_auth_account_password_hashes WHERE id = #{account.id.to_i}"
      )
      expect(hashes.to_i).to eq(0)
    end

    # The point of "off" being a complete configuration rather than a crippled
    # one: everything else still works.
    it "still signs in with an emailed code" do
      request_id = request_code

      expect(redeem(request_id).email).to eq(email)
    end

    it "still creates the account by code, with no password to choose" do
      redeem(request_code)

      account = SparrowAuth::Account.find_by_email(email)
      hashes = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM sparrow_auth_account_password_hashes WHERE id = #{account.id.to_i}"
      )
      expect(account).to be_verified
      expect(hashes.to_i).to eq(0)
    end

    # An account with no password enrolling a permanent way in. Rodauth
    # re-authenticates before enrolling a credential, and this is the case where
    # there is nothing to re-authenticate with — so the engine has to say so
    # rather than ask for a password the account has never had.
    it "still enrols and uses a passkey" do
      register_and_verify_without_a_password
      enroll_passkey(password: nil)
      post "/auth/logout"

      expect { sign_in_with_passkey }.to change { sessions_for }.by(1)
    end

    # Matched as an element, not as a substring: the page carries an inlined
    # stylesheet whose selectors include `input[type="password"]`, so searching
    # the body for that string finds the CSS and fails against correct markup.
    it "does not ask for a password on the sign-in page" do
      get "/auth/login"

      expect(password_fields_in(response.body)).to be_empty
    end
  end

  describe "on" do
    before { SparrowAuth.config.passwords_enabled = true }

    it "signs in with the correct password" do
      post "/auth/create-account", params: {
        login: email, password: password, "password-confirm": password
      }
      SparrowAuth::Account.where(email: email)
        .update_all(status_id: SparrowAuth::Account::VERIFIED)

      post "/auth/login", params: {login: email, password: password}

      expect(sessions_for).to eq(1)
    end

    it "asks for a password on the sign-in page" do
      get "/auth/login"

      expect(password_fields_in(response.body)).not_to be_empty
    end

    it "enforces the configured minimum length" do
      SparrowAuth.config.password_minimum_length = 12

      post "/auth/create-account", params: {
        login: email, password: "short", "password-confirm": "short"
      }

      expect(SparrowAuth::Account.find_by_email(email)).to be_nil
    end

    # A hook point, not an implementation: checking a password against a breach
    # corpus means shipping the corpus or calling somebody else's service.
    it "refuses a password the application says has been breached" do
      SparrowAuth.config.password_breached = ->(candidate) { candidate == password }

      post "/auth/create-account", params: {
        login: email, password: password, "password-confirm": password
      }

      expect(SparrowAuth::Account.find_by_email(email)).to be_nil
    end

    it "accepts one the application does not object to" do
      SparrowAuth.config.password_breached = ->(_candidate) { false }

      post "/auth/create-account", params: {
        login: email, password: password, "password-confirm": password
      }

      expect(SparrowAuth::Account.find_by_email(email)).to be_present
    end
  end
end
