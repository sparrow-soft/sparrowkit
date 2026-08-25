# frozen_string_literal: true

require "rails_helper"
require "uri"

# Passkeys, the first sign-in method on the ladder.
#
# Driven end to end against a software authenticator: real key pairs, real
# signatures, verified by the same code a platform credential goes through.
RSpec.describe "passkeys", type: :request do
  let(:email) { "newcomer@example.org" }
  let(:password) { "correct horse battery staple" }

  def register_and_sign_in
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
  end

  def account
    SparrowAuth::Account.find_by_email(email)
  end

  # Asked of a page behind SparrowAuth::RequiresLiveSession, which is what a
  # generated passkey screen is guarded by. It used to be the engine's own
  # /auth/passkeys; that page is the application's now, and this is the dummy
  # application's equivalent.
  def signed_in?
    get "/account-settings"
    response.status == 200
  rescue SparrowAuth::UnverifiedAccount
    false
  end

  describe "enrolling" do
    it "stores a credential for the account" do
      register_and_sign_in

      expect { enroll_passkey }.to change { account.webauthn_credentials.count }.by(1)
    end

    it "records the sign count the authenticator reported" do
      register_and_sign_in
      enroll_passkey

      expect(account.webauthn_credentials.first.sign_count).to be >= 0
    end

    it "lets one account enrol several devices" do
      register_and_sign_in
      enroll_passkey

      # A second authenticator is a second device, which is the case that must
      # work: people have a laptop and a phone, and losing one must not lock
      # them out of the account.
      @authenticator = WebAuthn::FakeClient.new(PasskeyHelpers::ORIGIN)
      enroll_passkey

      expect(account.webauthn_credentials.count).to eq(2)
    end

    # Rodauth passes the already-enrolled ids to the browser as `exclude`, which
    # is advice to a cooperating authenticator rather than a rule. The rule is
    # the composite primary key: the same credential cannot appear twice on one
    # account however it got there.
    it "cannot store the same credential twice for one account" do
      register_and_sign_in
      enroll_passkey
      existing = account.webauthn_credentials.first

      expect {
        ActiveRecord::Base.connection.execute(<<~SQL)
          INSERT INTO sparrow_auth_account_webauthn_keys
            (account_id, webauthn_id, public_key, sign_count)
          VALUES (#{existing.account_id.to_i},
                  #{ActiveRecord::Base.connection.quote(existing.webauthn_id)},
                  'x', 0)
        SQL
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end
  end

  # Adding a passkey is adding a permanent way in, so Rodauth re-authenticates
  # first. Worth a spec of its own: without it, somebody who walks up to an
  # unlocked laptop enrols their own passkey in silence and keeps access to the
  # account long after the owner has walked away.
  describe "enrolling requires re-authentication" do
    it "refuses without the account's password" do
      register_and_sign_in

      expect {
        enroll_passkey(password: "not the right password")
      }.not_to change { account.webauthn_credentials.count }
    end

    it "says so rather than failing silently" do
      register_and_sign_in
      enroll_passkey(password: "not the right password")

      expect(response.body).to include("invalid password")
    end
  end

  describe "signing in on return" do
    it "signs in with a passkey and no address typed" do
      register_and_sign_in
      enroll_passkey
      post "/auth/logout"
      expect(signed_in?).to be(false)

      sign_in_with_passkey

      expect(signed_in?).to be(true)
    end

    it "creates a revocable database session, like every other sign-in method" do
      register_and_sign_in
      enroll_passkey
      post "/auth/logout"

      expect { sign_in_with_passkey }.to change {
        ActiveRecord::Base.connection.select_value(
          "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
          "WHERE account_id = #{account.id.to_i}"
        )
      }.by(1)
    end

    it "fires the first-signin hook, so passkeys provision like any other sign-in method" do
      seen = []
      register_and_sign_in
      enroll_passkey
      post "/auth/logout"
      SparrowAuth::Account.where(email: email).update_all(first_signed_in_at: nil)
      SparrowAuth.config.after_first_signin = ->(account) { seen << account.email }

      sign_in_with_passkey

      expect(seen).to eq([email])
    end
  end

  # The one control WebAuthn provides against a cloned authenticator, and the
  # only part of the specification all three implementations this replaces got
  # right. It was worth checking that ours keeps it.
  describe "the signature counter" do
    def capture_assertion
      get "/auth/login"
      challenge = field_value(response.body, "webauthn_auth_challenge")
      hmac = field_value(response.body, "webauthn_auth_challenge_hmac")
      {
        webauthn_auth: authenticator.get(challenge: challenge, user_verified: true).to_json,
        webauthn_auth_challenge: challenge,
        webauthn_auth_challenge_hmac: hmac
      }
    end

    def sessions
      ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
        "WHERE account_id = #{account.id.to_i}"
      )
    end

    before do
      register_and_sign_in
      enroll_passkey
      post "/auth/logout"
    end

    it "advances as the authenticator reports it" do
      before_count = account.webauthn_credentials.first.sign_count
      sign_in_with_passkey

      expect(account.webauthn_credentials.first.sign_count).to be > before_count
    end

    # An assertion captured off the wire and sent again. The signature is
    # genuine and the challenge was genuinely issued; only the counter says it
    # is a repeat, which is the entire point of storing it.
    it "refuses the same assertion a second time" do
      assertion = capture_assertion
      post "/auth/webauthn-login", params: assertion
      expect(sessions).to eq(1)

      post "/auth/logout"
      expect(sessions).to eq(0)

      post "/auth/webauthn-login", params: assertion

      expect(sessions).to eq(0)
    end
  end

  describe "a revoked credential" do
    # The point of a management UI. Removing the passkey on a laptop somebody no
    # longer has must actually stop that laptop signing in.
    it "cannot sign in afterwards" do
      register_and_sign_in
      enroll_passkey
      credential = account.webauthn_credentials.first
      post "/auth/logout"

      credential.destroy!

      sign_in_with_passkey
      expect(signed_in?).to be(false)
    end
  end

  # The management screen is the application's, written by the application's own page. What it is written on top of is here: the
  # credential rows, reached through `current_account.webauthn_credentials`, so
  # that somebody else's passkey is not in the set rather than found and then
  # refused. That the generated screen reaches them that way is asserted where
  # it is written, in spec/generators/resource_generator_spec.rb.
  describe "managing credentials" do
    before do
      register_and_sign_in
      enroll_passkey
    end

    it "lists what is enrolled, oldest first" do
      enroll_passkey(client: another_authenticator)

      listed = account.webauthn_credentials.oldest_first.to_a

      expect(listed.size).to eq(2)
      expect(listed.map(&:created_at)).to eq(listed.map(&:created_at).sort)
    end

    it "gives every row something a person can tell apart from the next one" do
      credential = account.webauthn_credentials.first

      expect(credential.display_name).to be_present
      expect(credential.short_id).to eq(credential.webauthn_id[0, 8])
    end

    it "renames one, so a person can tell their devices apart" do
      credential = account.webauthn_credentials.first

      credential.update!(nickname: "Work laptop")

      expect(credential.reload.nickname).to eq("Work laptop")
      expect(credential.display_name).to eq("Work laptop")
    end

    it "refuses a nickname longer than the column holds" do
      credential = account.webauthn_credentials.first

      expect(credential.update(nickname: "x" * 65)).to be(false)
    end

    it "revokes one" do
      credential = account.webauthn_credentials.first

      expect { credential.destroy! }
        .to change { account.webauthn_credentials.count }.by(-1)
    end

    # A credential id is not a secret. It appears in form fields and in
    # JavaScript, so a lookup that matched only on the id would let anybody who
    # saw one revoke somebody else's passkey. Reached through the account's own
    # association, there is nothing to refuse: it is not there.
    it "does not find a credential belonging to somebody else" do
      mine = account.webauthn_credentials.first
      other = SparrowAuth::Account.create!(
        email: "other@example.org", status_id: SparrowAuth::Account::VERIFIED
      )

      expect(other.webauthn_credentials.find_by(webauthn_id: mine.webauthn_id)).to be_nil
      expect(mine.reload).to be_present
    end

    it "refuses to show anything to a signed-out visitor" do
      post "/auth/logout"

      expect { get "/account-settings" }.to raise_error(SparrowAuth::UnverifiedAccount)
    end
  end

  describe "the enrollment prompt" do
    it "is offered to an account with no passkey" do
      register_and_sign_in

      expect(account.passkey?).to be(false)
    end

    it "stops being offered once one is enrolled" do
      register_and_sign_in
      enroll_passkey

      expect(account.passkey?).to be(true)
    end
  end
end
