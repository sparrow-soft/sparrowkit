# frozen_string_literal: true

require "rails_helper"

# Whether an address has an account here is not a question this engine answers,
# and the sign-in form is the most obvious place to ask it.
#
# Rodauth's defaults answer it three ways. An unknown address gets 401 with the
# error on the email field. A registered but unverified one gets 403 and a
# different page entirely, because the verify_account feature overrides
# before_login_attempt and renders the resend view. A wrong password gets 401
# with the error on the password field. The unverified branch is the sharpest of
# the three, because Rodauth checks account status *before* it checks the
# password, so it answers for somebody who knows nothing but the address.
#
# These compare whole normalised response bodies rather than asserting on a
# message. An assertion on wording would have passed against every one of those
# three defaults, since the difference that mattered was the status code, the
# field carrying the error, and one line of markup in the footer.
RSpec.describe "sign-in does not reveal whether an address is registered", type: :request do
  let(:password) { "correct horse battery staple" }
  let(:wrong_password) { "not the right password at all" }

  def create_account(email)
    post "/auth/create-account", params: {
      login: email, password: password, "password-confirm": password
    }
  end

  def create_verified_account(email)
    create_account(email)
    SparrowAuth::Account.where(email: email).update_all(status_id: SparrowAuth::Account::VERIFIED)
  end

  def attempt_login(email, attempted_password)
    post "/auth/login", params: {login: email, password: attempted_password}
  end

  # The address is echoed into the form, and CSRF tokens are per-request. Both
  # vary for reasons that have nothing to do with whether an account exists.
  def normalised_body(email)
    response.body
      .gsub(email, "ADDRESS")
      .gsub(/[A-Za-z0-9+\/=_-]{40,}/, "TOKEN")
  end

  def sessions_for(email)
    account = SparrowAuth::Account.find_by_email(email)
    return 0 if account.nil?

    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_active_session_keys WHERE account_id = #{account.id.to_i}"
    )
  end

  before do
    create_account("unverified@example.org")
    create_verified_account("verified@example.org")

    # Creating those accounts leaves a flash pending, which would otherwise be
    # rendered into whichever response happens to come first and read as a
    # difference between the branches.
    get "/auth/login"

    SparrowMail.deliveries.clear
  end

  describe "a failed sign-in" do
    # Captured once and compared against, so a change that makes two branches
    # agree with each other but not with the unknown-address case still fails.
    let(:baseline) do
      attempt_login("stranger@example.org", wrong_password)
      {status: response.status, body: normalised_body("stranger@example.org")}
    end

    it "answers an unknown address and an unverified account identically" do
      expect(baseline[:status]).to eq(401)

      attempt_login("unverified@example.org", wrong_password)

      expect(response.status).to eq(baseline[:status])
      expect(normalised_body("unverified@example.org")).to eq(baseline[:body])
    end

    it "answers an unknown address and a wrong password identically" do
      expect(baseline[:status]).to eq(401)

      attempt_login("verified@example.org", wrong_password)

      expect(response.status).to eq(baseline[:status])
      expect(normalised_body("verified@example.org")).to eq(baseline[:body])
    end

    # The one an attacker gets for free: knowing only the address, with no
    # password at all, still must not distinguish an unverified account.
    it "answers an unverified account the same whether or not the password is right" do
      expect(baseline[:status]).to eq(401)

      attempt_login("unverified@example.org", password)

      expect(response.status).to eq(baseline[:status])
      expect(normalised_body("unverified@example.org")).to eq(baseline[:body])
    end

    # The footer link is the piece that survived the first fix: Rodauth renders
    # "resend the confirmation email" only for an address that is registered,
    # unverified and resendable, which is a complete oracle in one line of HTML.
    it "offers the resend link regardless of which address was submitted" do
      attempt_login("stranger@example.org", wrong_password)
      for_unknown = response.body.include?("verify-account-resend")

      attempt_login("unverified@example.org", wrong_password)

      expect(response.body.include?("verify-account-resend")).to eq(for_unknown)
    end
  end

  # The clock was answering what the page would not.
  #
  # An address with no account threw before any password work; one with an
  # account paid for a bcrypt comparison first, costing roughly forty times as
  # much — no statistics required, and a complete oracle underneath responses
  # that are byte-identical.
  #
  # Asserted as "the work happens" rather than by timing it. A timing assertion
  # would be flaky on a shared CI runner and would prove nothing about any real
  # deployment anyway: the cost depends on the machine, on bcrypt's configured
  # work factor, and on the database. SECURITY.md records the shape
  # as a ratio and says to measure your own.
  describe "the cost of answering" do
    it "does the same password work when no account matches" do
      expect(SparrowAuth::RodauthMain).to receive(:decoy_password_hash)
        .at_least(:once).and_call_original

      post "/auth/login", params: {login: "stranger@example.org", password: wrong_password}
    end

    it "compares against a value nothing can match" do
      hash = SparrowAuth::RodauthMain.decoy_password_hash(BCrypt::Engine::MIN_COST)

      expect(BCrypt::Password.new(hash) == "").to be(false)
      expect(BCrypt::Password.new(hash) == "password").to be(false)
    end

    it "reuses one decoy rather than generating one per request" do
      first = SparrowAuth::RodauthMain.decoy_password_hash(BCrypt::Engine::MIN_COST)

      expect(SparrowAuth::RodauthMain.decoy_password_hash(BCrypt::Engine::MIN_COST))
        .to equal(first)
    end

    # The failure that would otherwise be invisible: bcrypt bakes its cost into
    # each hash and every increment doubles the work, so a decoy fixed at one
    # cost stops matching the moment an application raises password_hash_cost.
    # It fails in the worst direction too — raising the cost to be safer would
    # reopen the gap, wider than it was before the decoy existed.
    it "builds the decoy at whatever cost the real hashes use" do
      [BCrypt::Engine::MIN_COST, BCrypt::Engine::MIN_COST + 1].each do |cost|
        hash = SparrowAuth::RodauthMain.decoy_password_hash(cost)

        expect(BCrypt::Password.new(hash).cost).to eq(cost)
      end
    end

    it "keeps a separate decoy per cost rather than reusing the first" do
      cheap = SparrowAuth::RodauthMain.decoy_password_hash(BCrypt::Engine::MIN_COST)
      dearer = SparrowAuth::RodauthMain.decoy_password_hash(BCrypt::Engine::MIN_COST + 1)

      expect(dearer).not_to eq(cheap)
    end

    # Rodauth's cost, not BCrypt's default. Asserted through the request rather
    # than by reading the constant, because what matters is which number the
    # sign-in path actually asks for.
    it "asks Rodauth what the cost is, rather than assuming bcrypt's default" do
      expect(SparrowAuth::RodauthMain).to receive(:decoy_password_hash)
        .with(BCrypt::Engine::MIN_COST).at_least(:once).and_call_original

      post "/auth/login", params: {login: "stranger@example.org", password: wrong_password}
    end
  end

  # Uniform answers are worthless if they were bought by letting people in.
  describe "what the uniform answer must not have cost" do
    it "still refuses an unverified account holding the correct password" do
      expect {
        attempt_login("unverified@example.org", password)
      }.not_to change { sessions_for("unverified@example.org") }

      expect(sessions_for("unverified@example.org")).to eq(0)
    end

    it "still signs in a verified account with the correct password" do
      attempt_login("verified@example.org", password)

      expect(response).to have_http_status(:found)
      expect(sessions_for("verified@example.org")).to eq(1)
    end
  end

  # The screen says the same sentence to everybody; the mailbox gets the truth.
  describe "telling the account owner what actually happened" do
    def notices
      SparrowMail.deliveries.select { |mail|
        mail.to.map(&:email).include?("unverified@example.org")
      }
    end

    it "tells the owner of an unverified account that signed in correctly" do
      attempt_login("unverified@example.org", password)

      expect(notices.size).to eq(1)
      expect(notices.first.subject).not_to match(/https?:/)
    end

    # Otherwise the sign-in form becomes a way to send somebody mail repeatedly
    # while knowing nothing about their account beyond the address.
    it "sends nothing when the password was wrong" do
      attempt_login("unverified@example.org", wrong_password)

      expect(notices).to be_empty
    end

    it "sends nothing for an address with no account" do
      attempt_login("stranger@example.org", password)

      expect(SparrowMail.deliveries).to be_empty
    end
  end

  # The second path that could be used to ask the same question.
  describe "resending a confirmation email" do
    def resend(email)
      post "/auth/verify-account-resend", params: {login: email}
    end

    it "answers unknown, verified and unverified addresses identically" do
      resend("stranger@example.org")
      baseline = [response.status, response.headers["Location"], flash[:notice], flash[:alert]]

      resend("verified@example.org")
      expect([response.status, response.headers["Location"], flash[:notice], flash[:alert]]).to eq(baseline)

      resend("unverified@example.org")
      expect([response.status, response.headers["Location"], flash[:notice], flash[:alert]]).to eq(baseline)
    end

    # Rodauth's default distinguished these by flash *key*, not only by wording,
    # which this engine's layout renders as a red alert rather than a grey
    # notice. Identical wording alone would not have closed it.
    it "uses the same flash key for every outcome" do
      resend("unverified@example.org")

      expect(flash[:alert]).to be_nil
      expect(flash[:notice]).to eq(SparrowAuth::RodauthMain::RESEND_NOTICE)
    end
  end
end
