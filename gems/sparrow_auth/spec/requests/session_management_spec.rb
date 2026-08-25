# frozen_string_literal: true

require "rails_helper"
require "uri"

# Seeing and ending what is signed in as you.
#
# Sessions have been database-backed since Phase 1 — that is what makes them
# revocable rather than merely expirable. What was missing until then was the
# part somebody can actually use: a session nobody can see is a session nobody
# will end.
#
# The page that shows them is the application's now, written by the application's own page. Two things stayed here, and they are the two
# that carry the security:
#
#   * SparrowAuth::Session, and the fact that every lookup goes through
#     `account.sessions` — so another person's row is not refused, it is not in
#     the set at all;
#   * SparrowAuth::RequiresLiveSession, which is why a session somebody revoked
#     a moment ago cannot reach a credentials page. AccountSettingsController in
#     the dummy application is a host controller that includes it, the way a
#     generated page does.
RSpec.describe "session management", type: :request do
  let(:password) { "correct horse battery staple" }
  let(:email) { "person@example.org" }

  def register_and_verify
    post "/auth/create-account", params: {
      login: email, password: password, "password-confirm": password
    }
    SparrowAuth::Account.where(email: email)
      .update_all(status_id: SparrowAuth::Account::VERIFIED)
    SparrowAuth::Account.find_by_email(email)
  end

  def sign_in(agent: "Mozilla/5.0 (Macintosh) TestBrowser/1.0")
    post "/auth/login",
      params: {login: email, password: password},
      headers: {"HTTP_USER_AGENT" => agent}
  end

  # What a generated page reads: the account's own rows, and which one is this
  # browser. Both come out of the guarded page rather than being recomputed
  # here, because recomputing them would test this spec's arithmetic.
  def session_id_of_this_browser
    get "/account-settings"
    response.body.split(" ").last
  end

  let!(:account) { register_and_verify }

  describe "the set a page can show" do
    it "holds a session for the browser that signed in" do
      sign_in

      expect(account.sessions.count).to eq(1)
    end

    # Four identical rows are not something anybody can act on, and "end the one
    # that is not me" is the whole reason for showing the list.
    it "records what signed in, so one row can be told from another" do
      sign_in(agent: "Mozilla/5.0 (Macintosh) TestBrowser/1.0")

      expect(account.sessions.last.user_agent).to include("TestBrowser")
    end

    it "says which row is the browser doing the asking" do
      sign_in

      expect(session_id_of_this_browser).to eq(account.sessions.first.session_id)
    end

    it "refuses to show anything to a signed-out visitor" do
      expect { get "/account-settings" }.to raise_error(SparrowAuth::UnverifiedAccount)
    end
  end

  describe "ending one" do
    it "removes the row" do
      sign_in
      row = account.sessions.first

      expect { row.destroy! }.to change { account.sessions.count }.by(-1)
    end

    # Revocable rather than expirable is the claim, so ending a session has to
    # end it now rather than at its next expiry.
    it "signs that browser out on its very next request" do
      sign_in
      account.sessions.first.destroy!

      expect { get "/account-settings" }.to raise_error(SparrowAuth::UnverifiedAccount)
    end

    # A session id is not a credential — the row holds an HMAC of the key in the
    # cookie — but it appears in a page, so a lookup matching on it alone would
    # let anybody who saw one end somebody else's session. Reached through
    # `account.sessions`, somebody else's row is simply not there.
    it "does not find another account's session, so there is nothing to end" do
      sign_in
      mine = account.sessions.first
      stranger = SparrowAuth::Account.create!(
        email: "stranger@example.org", status_id: SparrowAuth::Account::VERIFIED
      )

      expect(stranger.sessions.find_by(session_id: mine.session_id)).to be_nil
      expect(SparrowAuth::Session.where(session_id: mine.session_id)).to be_present
    end
  end

  # The bug the RequiresLiveSession concern was written for.
  #
  # These pages authenticate by reading the signed cookie, which answers who it
  # names rather than whether that session may still exist. Rodauth runs its own
  # active-session check on its own routes; a host application's pages are Rails
  # routes and never reach it, so revoking a session ended it everywhere except
  # the pages for managing credentials — leaving a session somebody had just
  # revoked able to remove their passkeys, which is exactly backwards.
  #
  # One page here rather than three, because there is one concern and the three
  # generated screens include exactly it. That the generated screens do include
  # it is asserted where they are written, in
  # spec/generators/resource_generator_spec.rb.
  describe "a revoked session, on a page guarded by the concern" do
    it "cannot reach it" do
      sign_in
      account.sessions.first.destroy!

      expect { get "/account-settings" }.to raise_error(SparrowAuth::UnverifiedAccount)
    end

    it "is refused even though the cookie still names a real, verified account" do
      sign_in
      account.sessions.first.destroy!

      expect(account.reload).to be_verified
      expect { get "/account-settings" }.to raise_error(SparrowAuth::UnverifiedAccount)
    end
  end

  describe "ending everything else" do
    # The button somebody reaches for having seen a row they do not recognise.
    # The set it acts on is `account.sessions` minus this browser, and both
    # halves of that come from the engine.
    it "leaves only the browser that asked" do
      sign_in(agent: "FirstBrowser")
      mine = session_id_of_this_browser

      # A second sign-in from elsewhere, without disturbing this browser's
      # cookies: the session rows are what matter, not who holds them.
      SparrowAuth::Session.create!(
        account_id: account.id, session_id: "another-browser-hmac",
        user_agent: "SecondBrowser", created_at: Time.current, last_use: Time.current
      )
      expect(account.sessions.count).to eq(2)

      account.sessions.where.not(session_id: mine).delete_all

      expect(account.sessions.pluck(:session_id)).to eq([mine])
    end

    it "keeps the asking browser signed in" do
      sign_in
      mine = session_id_of_this_browser
      SparrowAuth::Session.create!(
        account_id: account.id, session_id: "another-browser-hmac",
        user_agent: "SecondBrowser", created_at: Time.current, last_use: Time.current
      )

      account.sessions.where.not(session_id: mine).delete_all
      get "/account-settings"

      expect(response).to have_http_status(:ok)
    end

    it "touches nobody else's sessions" do
      sign_in
      mine = session_id_of_this_browser
      stranger = SparrowAuth::Account.create!(
        email: "stranger@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      SparrowAuth::Session.create!(
        account_id: stranger.id, session_id: "stranger-hmac",
        user_agent: "TheirBrowser", created_at: Time.current, last_use: Time.current
      )

      account.sessions.where.not(session_id: mine).delete_all

      expect(stranger.sessions.count).to eq(1)
    end
  end
end
