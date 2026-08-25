# frozen_string_literal: true

require "rails_helper"

# The adversarial suite for Gate 1.
#
# These are written from the attacker's side. An invitation grants access to
# whatever the inviting organization holds, so the interesting question is never
# "does the happy path work" but "what does someone who is not the invitee have
# to do to get in".
RSpec.describe SparrowAuth::Invitation do
  def account(email:, verified: true)
    SparrowAuth::Account.create!(
      email: email,
      status_id: verified ? SparrowAuth::Account::VERIFIED : SparrowAuth::Account::UNVERIFIED
    )
  end

  describe ".issue" do
    it "returns the token once and stores only a digest of it" do
      invitation, token = described_class.issue(email: "invitee@example.org")

      expect(token).to be_a(String)
      expect(token.length).to be >= 32
      expect(invitation.token_digest).not_to eq(token)
      expect(described_class.pluck(:token_digest)).not_to include(token)
    end

    it "normalises the address, so case cannot be used to route around binding" do
      invitation, _ = described_class.issue(email: "  Invitee@Example.ORG ")

      expect(invitation.email).to eq("invitee@example.org")
    end

    it "expires" do
      invitation, _ = described_class.issue(email: "invitee@example.org")

      expect(invitation.expires_at).to be > Time.current
      expect(invitation.expires_at).to be <= Time.current + SparrowAuth.config.invitation_expiry
    end

    it "supersedes an earlier pending invitation to the same address" do
      _, first_token = described_class.issue(email: "invitee@example.org")
      _, second_token = described_class.issue(email: "invitee@example.org")

      expect(described_class.pending.where(email: "invitee@example.org").count).to eq(1)
      expect { described_class.redeem!(token: first_token, account: account(email: "invitee@example.org")) }
        .to raise_error(SparrowAuth::InvalidInvitation)
      expect(second_token).not_to eq(first_token)
    end
  end

  describe ".redeem!" do
    let(:invitee) { account(email: "invitee@example.org") }

    it "accepts when the verified invitee presents their own token" do
      invitation, token = described_class.issue(email: "invitee@example.org")

      redeemed = described_class.redeem!(token: token, account: invitee)

      expect(redeemed.id).to eq(invitation.id)
      expect(redeemed.accepted_at).to be_present
      expect(redeemed.accepted_by_id).to eq(invitee.id)
    end

    it "matches the address case-insensitively" do
      _, token = described_class.issue(email: "Invitee@Example.org")
      holder = account(email: "invitee@example.org")

      expect { described_class.redeem!(token: token, account: holder) }.not_to raise_error
    end

    # The attack Timeliner already closed, and which must stay closed. A link in
    # an inbox is not a bearer permission: forwarding it, or leaking it through
    # a shared mailbox or a mailing list, must not hand over the grant.
    context "forwarded link" do
      it "refuses an account that is not the invitee" do
        _, token = described_class.issue(email: "invitee@example.org")
        bystander = account(email: "someone.else@example.org")

        expect { described_class.redeem!(token: token, account: bystander) }
          .to raise_error(SparrowAuth::InvitationNotYours)
      end

      it "leaves the invitation usable by the real invitee afterwards" do
        _, token = described_class.issue(email: "invitee@example.org")
        bystander = account(email: "someone.else@example.org")

        expect { described_class.redeem!(token: token, account: bystander) }
          .to raise_error(SparrowAuth::InvitationNotYours)

        expect { described_class.redeem!(token: token, account: invitee) }.not_to raise_error
      end
    end

    # The attack Timeliner did not close, and the reason mandatory verification
    # is not configurable. Registering as the invitee costs nothing and proves
    # nothing; without this check it is enough to take their place.
    context "pre-registered unverified address" do
      it "refuses an account whose address has never been verified" do
        _, token = described_class.issue(email: "invitee@example.org")
        impostor = account(email: "invitee@example.org", verified: false)

        expect { described_class.redeem!(token: token, account: impostor) }
          .to raise_error(SparrowAuth::InvitationNotYours)
      end

      it "refuses even though the address matches exactly" do
        _, token = described_class.issue(email: "invitee@example.org")
        impostor = account(email: "invitee@example.org", verified: false)

        expect(impostor.email).to eq("invitee@example.org")
        expect(impostor).not_to be_verified
        expect { described_class.redeem!(token: token, account: impostor) }
          .to raise_error(SparrowAuth::AccessError)
      end

      it "accepts once that same account verifies" do
        _, token = described_class.issue(email: "invitee@example.org")
        holder = account(email: "invitee@example.org", verified: false)

        expect { described_class.redeem!(token: token, account: holder) }
          .to raise_error(SparrowAuth::InvitationNotYours)

        holder.update!(status_id: SparrowAuth::Account::VERIFIED)

        expect { described_class.redeem!(token: token, account: holder) }.not_to raise_error
      end
    end

    context "replay" do
      it "refuses a token that has already been redeemed" do
        _, token = described_class.issue(email: "invitee@example.org")
        described_class.redeem!(token: token, account: invitee)

        expect { described_class.redeem!(token: token, account: invitee) }
          .to raise_error(SparrowAuth::InvalidInvitation)
      end

      it "records only the first acceptance" do
        invitation, token = described_class.issue(email: "invitee@example.org")
        described_class.redeem!(token: token, account: invitee)
        first_accepted_at = invitation.reload.accepted_at

        begin
          described_class.redeem!(token: token, account: invitee)
        rescue SparrowAuth::InvalidInvitation
          nil
        end

        expect(invitation.reload.accepted_at).to eq(first_accepted_at)
      end
    end

    context "expiry" do
      it "refuses an expired token" do
        invitation, token = described_class.issue(email: "invitee@example.org")
        invitation.update!(expires_at: 1.second.ago)

        expect { described_class.redeem!(token: token, account: invitee) }
          .to raise_error(SparrowAuth::InvalidInvitation)
      end
    end

    context "a token that was never issued" do
      it "is refused" do
        expect { described_class.redeem!(token: "not-a-real-token", account: invitee) }
          .to raise_error(SparrowAuth::InvalidInvitation)
      end

      # Telling an attacker which of "no such token", "expired" and "already
      # used" applies tells them whether a token they guessed ever existed.
      it "gives the same message as an expired one and an already-used one" do
        invitation, used_token = described_class.issue(email: "invitee@example.org")
        described_class.redeem!(token: used_token, account: invitee)

        _, expired_token = described_class.issue(email: "other@example.org")
        described_class.find_by!(email: "other@example.org").update!(expires_at: 1.second.ago)

        messages = ["not-a-real-token", used_token, expired_token].map do |token|
          described_class.redeem!(token: token, account: invitee)
          nil
        rescue SparrowAuth::AccessError => e
          e.message
        end

        expect(messages.uniq.size).to eq(1)
        expect(invitation).to be_present
      end
    end

    context "a closed account" do
      it "is refused even when the address matches and was once verified" do
        _, token = described_class.issue(email: "invitee@example.org")
        closed = account(email: "invitee@example.org")
        closed.update!(status_id: SparrowAuth::Account::CLOSED)

        expect { described_class.redeem!(token: token, account: closed) }
          .to raise_error(SparrowAuth::InvitationNotYours)
      end
    end
  end

  describe "#pending?" do
    it "is false once accepted" do
      _, token = described_class.issue(email: "invitee@example.org")
      invitation = described_class.redeem!(token: token, account: account(email: "invitee@example.org"))

      expect(invitation).not_to be_pending
    end

    it "is false once expired" do
      invitation, _ = described_class.issue(email: "invitee@example.org")
      invitation.update!(expires_at: 1.second.ago)

      expect(invitation).not_to be_pending
    end
  end

  # The screen a person lands on from an invitation email has to show them what
  # they are being invited to before they accept it, and the token is the only
  # thing they arrive holding. `digest` is private, so without a public lookup a
  # application cannot build that page at all.
  #
  # the application's own page wrote a page calling this for
  # a release in which it did not exist, so the generated screen raised
  # NoMethodError on its first visit.
  describe ".find_by_token" do
    it "finds the invitation a token names" do
      invitation, token = described_class.issue(email: "invitee@example.org")

      expect(described_class.find_by_token(token)).to eq(invitation)
    end

    it "answers nil for a token nothing was issued for" do
      expect(described_class.find_by_token("not-a-token")).to be_nil
    end

    it "answers nil rather than raising for a blank one" do
      expect(described_class.find_by_token(nil)).to be_nil
    end

    # It answers "which invitation is this", not "may you have it". A lookup
    # that quietly refused would tempt somebody to read a non-nil return as
    # permission -- accepting goes through redeem!, which checks the address and
    # the account's verification for itself.
    it "authorises nothing: an expired invitation is still found" do
      invitation, token = described_class.issue(email: "invitee@example.org")
      invitation.update!(expires_at: 1.day.ago)

      expect(described_class.find_by_token(token)).to eq(invitation)
      expect(described_class.find_by_token(token)).not_to be_pending
    end
  end
end
