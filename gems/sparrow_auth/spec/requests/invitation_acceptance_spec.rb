# frozen_string_literal: true

require "rails_helper"
require "uri"

# Accepting an invitation, driven the way the acceptance page drives it.
#
# There is no acceptance page here: SparrowKit ships no screens. The whole
# decision is in Invitation.redeem!, which raises, so a page that forgot to ask
# could not accidentally allow anything — and this file is that decision put
# under the same attacks the page would have faced.
#
# The accounts are still registered and verified over Rodauth's own routes
# rather than created with a status column set. The difference matters: the
# attack this closes is somebody registering as the invitee and never
# confirming, and an account fabricated in a spec would not have gone through
# the road that produces one.
RSpec.describe "accepting an invitation", type: :request do
  let(:password) { "correct horse battery staple" }

  def register_and_verify(email)
    post "/auth/create-account", params: {
      login: email, password: password, "password-confirm": password
    }
    url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
    key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
    # GET first, the way somebody clicking the emailed link does. Rodauth 2.47
    # takes the key from the session that GET establishes rather than from the
    # POST body, so a POST on its own is refused -- and a POST on its own is not
    # a thing a browser ever does.
    get "/auth/verify-account", params: {key: key}
    post "/auth/verify-account", params: {key: key}
    post "/auth/logout"
    SparrowAuth::Account.find_by_email(email)
  end

  def register_without_verifying(email)
    post "/auth/create-account", params: {
      login: email, password: password, "password-confirm": password
    }
    SparrowAuth::Account.find_by_email(email)
  end

  describe "the invitee" do
    it "can accept their own invitation" do
      invitee = register_and_verify("invitee@example.org")
      _, token = SparrowAuth::Invitation.issue(email: "invitee@example.org")

      SparrowAuth::Invitation.redeem!(token: token, account: invitee)

      expect(SparrowAuth::Invitation.last.accepted_at).to be_present
    end
  end

  describe "a forwarded link" do
    it "does not let a different signed-in account accept" do
      register_and_verify("invitee@example.org")
      bystander = register_and_verify("bystander@example.org")
      _, token = SparrowAuth::Invitation.issue(email: "invitee@example.org")

      expect { SparrowAuth::Invitation.redeem!(token: token, account: bystander) }
        .to raise_error(SparrowAuth::AccessError)

      expect(SparrowAuth::Invitation.last.accepted_at).to be_nil
    end
  end

  describe "a pre-registered unverified address" do
    it "does not let an unverified account accept, even with the exact address" do
      impostor = register_without_verifying("invitee@example.org")
      _, token = SparrowAuth::Invitation.issue(email: "invitee@example.org")

      expect { SparrowAuth::Invitation.redeem!(token: token, account: impostor) }
        .to raise_error(SparrowAuth::AccessError)

      expect(SparrowAuth::Invitation.last.accepted_at).to be_nil
    end
  end

  describe "nobody signed in" do
    # The page turns a signed-out visitor away before a token is looked at, so
    # that somebody with no account cannot probe which tokens exist. Even if it
    # did not, the model refuses: there is no account to match the address
    # against, and an invitation names an address.
    it "cannot accept" do
      _, token = SparrowAuth::Invitation.issue(email: "invitee@example.org")

      expect { SparrowAuth::Invitation.redeem!(token: token, account: nil) }
        .to raise_error(SparrowAuth::AccessError)

      expect(SparrowAuth::Invitation.last.accepted_at).to be_nil
    end
  end

  describe "what a refusal reveals" do
    # A page that answered differently for "no such token" than for "not yours"
    # would let somebody signed in as anybody enumerate which tokens exist. Both
    # refusals are one class of error, so a page rescuing AccessError — which is
    # what the generated one does — answers them with one response, exactly as
    # the engine's own page did.
    it "refuses a real invitation belonging to someone else as the same kind of error as a token that never existed" do
      bystander = register_and_verify("bystander@example.org")
      _, real_token = SparrowAuth::Invitation.issue(email: "invitee@example.org")

      real = refusal_from { SparrowAuth::Invitation.redeem!(token: real_token, account: bystander) }
      invented = refusal_from {
        SparrowAuth::Invitation.redeem!(token: "a-token-that-never-existed", account: bystander)
      }

      expect(real).to be_a(SparrowAuth::AccessError)
      expect(invented).to be_a(SparrowAuth::AccessError)
    end

    # Asked of the class rather than the message, which is exactly as far as the
    # original went: it drove the engine's own acceptance page and compared the
    # two HTTP statuses, and that page rendered one status for every AccessError.
    # The two messages are NOT the same — "issued to a different address" against
    # "not valid" — and the generated page puts the message on screen. Whether
    # that is a leak worth closing is a question about the engine's errors, not
    # about this spec, and it is written up in the report for this branch.
    def refusal_from
      yield
      raise "expected a refusal and got none"
    rescue SparrowAuth::AccessError => e
      e
    end
  end
end
