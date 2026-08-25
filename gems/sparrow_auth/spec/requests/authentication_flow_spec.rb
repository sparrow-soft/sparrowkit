# frozen_string_literal: true

require "rails_helper"
require "uri"

# Gate 1's other half: the engine mounts in a bare host application, and signup
# through verification through signin works end to end against a real Rails
# stack and a real database.
#
# These drive the Rodauth routes over HTTP rather than calling Rodauth's API,
# because what an application actually depends on is the mounted behaviour, and
# a mounting mistake is invisible to any test that skips the router.
RSpec.describe "the authentication flow", type: :request do
  let(:email) { "newcomer@example.org" }
  let(:password) { "correct horse battery staple" }

  def create_account
    post "/auth/create-account", params: {
      login: email,
      password: password,
      "password-confirm": password
    }
  end

  def verification_url_from_last_email
    SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
  end

  # The emailed link opens a confirmation page; verifying is the POST that page
  # submits. Following the link alone must not verify anything, or every link
  # scanner that prefetches URLs would verify accounts on the recipient's behalf.
  def follow_verification_link
    url = verification_url_from_last_email
    key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
    get url
    # GET first, the way somebody clicking the emailed link does. Rodauth 2.47
    # takes the key from the session that GET establishes rather than from the
    # POST body, so a POST on its own is refused -- and a POST on its own is not
    # a thing a browser ever does.
    get "/auth/verify-account", params: {key: key}
    post "/auth/verify-account", params: {key: key}
  end

  describe "mounting" do
    it "serves Rodauth's routes under the engine's mount point" do
      get "/auth/login"

      expect(response).to have_http_status(:ok)
    end

    # The rule, stated as a test. SparrowKit ships no end-user pages, so the
    # engine draws no routes at all — the sign-in screen, the invitation
    # landing page and the three account pages are the buyer's, written by
    # `rails generate sparrowkit:screens`.
    #
    # Rodauth's routes are unaffected by that and are checked above: they come
    # from Roda middleware sitting above the Rails router, at
    # config.path_prefix, and are not part of any route set. Which is why this
    # engine still has to be mounted somewhere for them to be reached.
    it "draws no routes of its own" do
      expect(SparrowAuth::Engine.routes.routes.to_a).to be_empty
    end
  end

  describe "signup" do
    it "creates an account" do
      expect { create_account }.to change(SparrowAuth::Account, :count).by(1)
    end

    it "creates it unverified" do
      create_account

      expect(SparrowAuth::Account.find_by_email(email)).not_to be_verified
    end

    it "sends a verification email through sparrow_mail" do
      expect { create_account }.to change { SparrowMail.deliveries.size }.by(1)

      delivery = SparrowMail.deliveries.last
      expect(delivery.to.first.email).to eq(email)
      expect(delivery.stream).to eq(:transactional)
    end

    # A subject line is the part of a message most likely to appear on a lock
    # screen or in a mail gateway's logs.
    it "keeps the link out of the subject" do
      create_account

      expect(SparrowMail.deliveries.last.subject).to eq("Confirm your email address")
      expect(SparrowMail.deliveries.last.subject).not_to include("http")
    end
  end

  describe "verification" do
    it "verifies the account when the link is followed" do
      create_account
      account = SparrowAuth::Account.find_by_email(email)

      follow_verification_link

      expect(account.reload).to be_verified
    end

    # Mailbox security scanners follow links in incoming mail. If merely
    # fetching the link verified the address, a scanner would confirm it on the
    # recipient's behalf and the confirmation would prove nothing.
    it "does not verify from following the link alone" do
      create_account
      account = SparrowAuth::Account.find_by_email(email)

      get verification_url_from_last_email

      expect(account.reload).not_to be_verified
    end
  end

  describe "signin" do
    # The grace period is zero deliberately. Rodauth's default lets an
    # unverified account log in for a while, which is a reasonable product
    # decision and the wrong one here: that window is exactly when an
    # unverified address could be used to accept someone else's invitation.
    it "refuses an unverified account" do
      create_account

      post "/auth/login", params: {login: email, password: password}

      expect(session_account_id).to be_nil
    end

    it "signs in a verified account" do
      create_account
      follow_verification_link

      post "/auth/login", params: {login: email, password: password}

      expect(session_account_id).to eq(SparrowAuth::Account.find_by_email(email).id)
    end

    # Database-backed from day one, which is what makes a session revocable
    # rather than merely expirable.
    it "records the session in the database" do
      create_account
      follow_verification_link
      post "/auth/login", params: {login: email, password: password}

      count = ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM sparrow_auth_account_active_session_keys"
      )
      expect(count).to eq(1)
    end

    it "drops the session row on logout, so the session is gone rather than merely expired" do
      create_account
      follow_verification_link
      post "/auth/login", params: {login: email, password: password}
      post "/auth/logout"

      count = ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM sparrow_auth_account_active_session_keys"
      )
      expect(count).to eq(0)
    end
  end

  describe "anti-enumeration" do
    # Whether an address already has an account is not a question this should
    # answer, to anyone, on any path.
    it "gives the same response creating an account that already exists" do
      create_account
      first_status = response.status
      first_location = response.location

      create_account

      expect(response.status).to eq(first_status)
      expect(response.location).to eq(first_location)
    end

    it "creates no second account" do
      create_account
      expect { create_account }.not_to change(SparrowAuth::Account, :count)
    end

    # The attempt is invisible in the response by design, so this is how the
    # news reaches the only person entitled to hear it.
    it "tells the address's real owner instead" do
      create_account
      create_account

      expect(SparrowMail.deliveries.last.subject)
        .to eq("Someone tried to create an account with your address")
      expect(SparrowMail.deliveries.last.to.first.email).to eq(email)
    end

    # A notification that fails must not produce a different response than one
    # that succeeds, or the oracle is back by another route.
    it "gives the same response even when the notification cannot be sent" do
      create_account
      first_status = response.status
      SparrowMail::Adapters::Test.fail_with(SparrowMail::ProviderError)

      create_account

      expect(response.status).to eq(first_status)
    ensure
      SparrowMail::Adapters::Test.stop_failing
    end
  end

  def session_account_id
    session[:account_id] || session["account_id"]
  end
end
