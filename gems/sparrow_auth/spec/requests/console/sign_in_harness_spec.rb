# frozen_string_literal: true

require "rails_helper"

# The development sign-in harness on the auth panel.
#
# SparrowKit serves no sign-in page any more, and there is no easy way to see
# what a viewer meets as opposed to an admin without several browsers and a lot
# of patience. This is that, on one page.
#
# What is under test is mostly one claim: that it takes no shortcut. It asks
# SparrowAuth::SignIn for a code, reads it back out of the mailbox, and redeems
# it — so every rule that governs a real sign-in governs this one, and there is
# no second path through the code that does not. A harness that wrote the
# session directly would pass a "signs somebody in" test and prove nothing.
HARNESS = "/sparrowkit/auth/sign-in-as"

RSpec.describe "signing in from the auth panel", type: :request do
  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
    SparrowMail.deliveries.clear
  end

  def verified(email)
    SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)
  end

  describe "signing in" do
    it "signs the browser in as the chosen account" do
      account = verified("owner@example.test")

      post HARNESS, params: {account_id: account.id}

      expect(flash[:notice]).to include(account.email)
      get "/account-settings"
      expect(response.body).to start_with(account.email)
    end

    # The point of "no shortcut": what comes out is a row in the active-sessions
    # table, so the session is revocable and shows up on the sessions screen
    # exactly like a session anybody else gets.
    it "leaves a real session, not a forged cookie" do
      account = verified("owner@example.test")

      post HARNESS, params: {account_id: account.id}

      expect(account.sessions.count).to eq(1)
    end

    it "records the sign-in the way every other sign-in is recorded" do
      account = verified("owner@example.test")

      expect { post HARNESS, params: {account_id: account.id} }
        .to change(SparrowAuth::AuthEvent, :count)
    end

    it "consumes the code, so it cannot be redeemed a second time" do
      account = verified("owner@example.test")

      post HARNESS, params: {account_id: account.id}

      expect(SparrowAuth::OneTimeCode.where(email: account.email, consumed_at: nil)).to be_empty
    end

    it "lets the developer swap to somebody else" do
      first = verified("viewer@example.test")
      second = verified("admin@example.test")

      post HARNESS, params: {account_id: first.id}
      post HARNESS, params: {account_id: second.id}

      get "/account-settings"
      expect(response.body).to start_with(second.email)
    end
  end

  describe "the rules it inherits by not going round them" do
    # Not a check written into the harness. SignIn refuses to send a code to an
    # unverified address, so there is nothing to read back and nothing to
    # redeem. The message says which of the three reasons applies.
    it "cannot sign in an account that has never verified its address" do
      account = SparrowAuth::Account.create!(
        email: "unverified@example.test", status_id: SparrowAuth::Account::UNVERIFIED
      )

      post HARNESS, params: {account_id: account.id}

      expect(flash[:alert]).to be_present
      expect(account.sessions.count).to eq(0)
    end

    # One code per address per minute, which the harness reports rather than
    # works around. A harness with its own way past the limiter would be a way
    # past the limiter.
    it "is refused by the rate limit, and says so in words" do
      account = verified("owner@example.test")

      post HARNESS, params: {account_id: account.id}
      post HARNESS, params: {account_id: account.id}

      expect(flash[:alert]).to match(/one message a minute/i)
    end

    it "refuses an account id that is not an account" do
      post HARNESS, params: {account_id: 0}

      expect(flash[:alert]).to eq("No such account.")
    end
  end

  describe "when the code went somewhere it cannot be read" do
    # A real provider means the code is in a real mailbox. Saying so beats
    # failing silently, and beats the alternative somebody would reach for:
    # reading the code out of the database, which is impossible anyway because
    # only its digest is stored.
    it "says the code is in the developer's own mailbox" do
      account = verified("owner@example.test")
      allow(SparrowMail).to receive(:readable_deliveries).and_return([])
      allow(SparrowMail.configuration).to receive(:adapter).and_return(:postmark)

      post HARNESS, params: {account_id: account.id}

      expect(flash[:alert]).to match(/through your mail provider/i)
    end

    it "sends somebody to the Mail panel when nothing is configured at all" do
      account = verified("owner@example.test")
      allow(SparrowMail).to receive(:readable_deliveries).and_return([])
      allow(SparrowMail.configuration).to receive(:adapter).and_return(nil)

      post HARNESS, params: {account_id: account.id}

      expect(flash[:alert]).to match(/Mail panel/i)
    end
  end

  describe "the panel itself" do
    it "lists verified accounts to choose from" do
      verified("owner@example.test")

      get "/sparrowkit/auth"

      expect(response.body).to include("Sign in as somebody")
      expect(response.body).to include("owner@example.test")
    end

    it "offers no unverified account, because none of them could be signed in" do
      SparrowAuth::Account.create!(
        email: "unverified@example.test", status_id: SparrowAuth::Account::UNVERIFIED
      )

      get "/sparrowkit/auth"

      expect(response.body).not_to include("unverified@example.test")
    end

    it "points at the seed task when there is nobody at all" do
      get "/sparrowkit/auth"

      expect(response.body).to include("sparrow_auth:seed")
    end

    # An application that has not written a sign-in page has nowhere for anybody
    # to sign in, and the symptom is a 404 at a path nobody wrote. The panel says
    # so, and points at the one page that does exist: Rodauth's own.
    it "says so when the application has no sign-in screen of its own" do
      allow(SparrowAuth.config).to receive(:sign_in_path).and_return("/nothing-is-here")

      get "/sparrowkit/auth"

      expect(response.body).to include("/auth/login")
      expect(response.body).to include("has no sign-in page yet")
    end

    it "stays quiet about that once a sign-in page exists" do
      get "/sparrowkit/auth"

      expect(response.body).not_to include("has no sign-in page yet")
    end
  end
end
