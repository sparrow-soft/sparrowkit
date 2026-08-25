# frozen_string_literal: true

require "rails_helper"

# An invitation that names an organization.
#
# Until now every invitation was an invitation to the product, and joining an
# organization was left to the host's after_invitation_accepted hook. That is
# still true of an invitation naming no organization. What is new is the other
# kind, which admin needs: a row that says which organization it is an
# invitation to, so a page can list "the invitations to mine" without listing
# everybody else's.
#
# The seating it does on acceptance is a grant of access, so it gets the same
# treatment as every other grant here — tested from the attacker's side.
RSpec.describe SparrowAuth::Invitation, "bound to an organization" do
  def account(email:, verified: true)
    SparrowAuth::Account.create!(
      email: email,
      status_id: verified ? SparrowAuth::Account::VERIFIED : SparrowAuth::Account::UNVERIFIED
    )
  end

  # An invitation into an organization is now issued BY somebody, and the role
  # it offers is checked against what that person holds. So every issue here
  # names an inviter, and the organization has one from the moment it exists.
  let(:boss) { account(email: "boss@example.org") }
  let(:org) { SparrowAuth::Organization.create_with_owner!(account: boss, name: "Acme") }
  let(:invitee) { account(email: "invitee@example.org") }

  describe "accepting one" do
    it "seats the invitee at the role the invitation named" do
      _invitation, token = described_class.issue(
        email: invitee.email, organization: org, role: :admin, invited_by: boss
      )

      described_class.redeem!(token: token, account: invitee)

      expect(invitee.membership_in(org).role).to eq("admin")
    end

    # It used to default to :member. A default that grants is an offer nobody
    # stated and nobody reviewed, so the role is now named or there is no
    # invitation.
    it "refuses to issue one that names no role" do
      expect {
        described_class.issue(email: invitee.email, organization: org, invited_by: boss)
      }.to raise_error(ArgumentError, /name the role/)
    end

    # Without an inviter there is nothing to check the offered role against, so
    # the offer cannot be reviewed at all.
    it "refuses to issue one that says nobody offered it" do
      expect {
        described_class.issue(email: invitee.email, organization: org, role: :member)
      }.to raise_error(ArgumentError, /who is offering it/)
    end

    it "seats them in nothing when the invitation named no organization" do
      _invitation, token = described_class.issue(email: invitee.email)

      described_class.redeem!(token: token, account: invitee)

      expect(invitee.memberships).to be_empty
    end
  end

  describe "what an invitation may not be used for" do
    # The one that matters. If an invitation could set the role of somebody
    # already inside, then anybody who can send one could demote an owner — or
    # promote themselves, by inviting their own address.
    it "does not change the role of somebody already in the organization" do
      org.memberships.create!(account: invitee, role: :owner)
      _invitation, token = described_class.issue(
        email: invitee.email, organization: org, role: :member, invited_by: boss
      )

      described_class.redeem!(token: token, account: invitee)

      expect(invitee.membership_in(org).role).to eq("owner")
    end

    it "cannot name a role with no organization to hold it" do
      invitation = described_class.new(
        email: "x@example.org", token_digest: "d", role: "admin",
        expires_at: 1.day.from_now
      )

      expect(invitation).not_to be_valid
      expect(invitation.errors[:role].join).to include("without an organization")
    end

    it "is refused at the database too, not only in the model" do
      # Timestamps computed in Ruby and quoted by the adapter, because this
      # raw INSERT runs against both supported databases and `now() +
      # interval` is PostgreSQL's spelling alone.
      expires = ActiveRecord::Base.connection.quote(1.day.from_now)

      expect {
        ActiveRecord::Base.connection.execute(<<~SQL)
          INSERT INTO sparrow_auth_invitations (email, token_digest, role, expires_at, created_at, updated_at)
          VALUES ('x@example.org', 'd', 'owner', #{expires}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      }.to raise_error(ActiveRecord::StatementInvalid, /role_needs_organization/)
    end

    # The address check has always been the load-bearing one. Adding an
    # organization to the row must not have moved it.
    it "still refuses an account whose address does not match" do
      _invitation, token = described_class.issue(
        email: "invitee@example.org", organization: org, role: :admin, invited_by: boss
      )
      someone_else = account(email: "someone.else@example.org")

      expect {
        described_class.redeem!(token: token, account: someone_else)
      }.to raise_error(SparrowAuth::InvitationNotYours)

      expect(someone_else.memberships).to be_empty
      expect(org.memberships.map(&:account)).to eq([boss])
    end

    it "still refuses an account that has not verified the address" do
      unverified = account(email: "unverified@example.org", verified: false)
      _invitation, token = described_class.issue(
        email: unverified.email, organization: org, role: :admin, invited_by: boss
      )

      expect {
        described_class.redeem!(token: token, account: unverified)
      }.to raise_error(SparrowAuth::InvitationNotYours)

      expect(unverified.memberships).to be_empty
      expect(org.memberships.map(&:account)).to eq([boss])
    end
  end

  describe "superseding" do
    # Two live links to one address in one organization means revoking one
    # accomplishes nothing.
    it "replaces an earlier pending invitation to the same organization" do
      _first, first_token = described_class.issue(
        email: invitee.email, organization: org, role: :member, invited_by: boss
      )
      _second, _second_token = described_class.issue(
        email: invitee.email, organization: org, role: :member, invited_by: boss
      )

      expect(described_class.for_organization(org).pending.count).to eq(1)
      expect {
        described_class.redeem!(token: first_token, account: invitee)
      }.to raise_error(SparrowAuth::InvalidInvitation)
    end

    # But an invitation to join Acme must not cancel an invitation to join
    # Globex. They are different grants to the same person.
    it "leaves an invitation to a different organization alone" do
      elsewhere = account(email: "elsewhere@example.org")
      other = SparrowAuth::Organization.create_with_owner!(account: elsewhere, name: "Globex")
      _first, first_token = described_class.issue(
        email: invitee.email, organization: other, role: :member, invited_by: elsewhere
      )
      described_class.issue(
        email: invitee.email, organization: org, role: :member, invited_by: boss
      )

      expect { described_class.redeem!(token: first_token, account: invitee) }
        .not_to raise_error
      expect(invitee.membership_in(other)).to be_present
    end

    # Proved rather than assumed, because PostgreSQL treats each NULL
    # organization_id as its own value: a single (email, organization_id)
    # unique index would exempt every invitation naming no organization from
    # the rule entirely. The schema says this with a second partial unique
    # index over exactly those rows rather than with NULLS NOT DISTINCT, which
    # would cost a PostgreSQL 15 floor for one clause.
    it "still allows only one live invitation per address with no organization" do
      described_class.issue(email: invitee.email)

      expires = ActiveRecord::Base.connection.quote(1.day.from_now)

      expect {
        ActiveRecord::Base.connection.execute(<<~SQL)
          INSERT INTO sparrow_auth_invitations (email, token_digest, expires_at, created_at, updated_at)
          VALUES ('#{invitee.email}', 'another', #{expires}, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP)
        SQL
      }.to raise_error(ActiveRecord::RecordNotUnique)
    end

    it "leaves an invitation naming no organization alone" do
      _plain, plain_token = described_class.issue(email: invitee.email)
      described_class.issue(
        email: invitee.email, organization: org, role: :member, invited_by: boss
      )

      expect { described_class.redeem!(token: plain_token, account: invitee) }
        .not_to raise_error
    end

    # An expired invitation is still an unaccepted one, so it still occupies a
    # slot in the unique indexes while `pending` filters it out of every list.
    # If anything supersedes less than those indexes cover, the leftover row is
    # both invisible and unremovable, and re-inviting that address raises
    # RecordNotUnique in the caller's face rather than sending an invitation.
    #
    # That was live until the resource columns were removed: they were part of
    # the supersede and no part of the index, so an invitation to a project
    # inside an organization permanently blocked inviting the same person to
    # the organization itself. Both halves are asserted here, because the
    # coupling is easy to break again from either side.
    it "re-invites an address whose earlier invitation has expired" do
      described_class.issue(
        email: invitee.email, organization: org, role: :member, invited_by: boss
      )

      travel(SparrowAuth.config.invitation_expiry + 1.day) do
        expect(described_class.for_organization(org).pending).to be_empty

        _reissued, token = described_class.issue(
          email: invitee.email, organization: org, role: :member, invited_by: boss
        )

        expect { described_class.redeem!(token: token, account: invitee) }.not_to raise_error
      end
    end

    it "re-invites an address to the product after its invitation has expired" do
      described_class.issue(email: invitee.email)

      travel(SparrowAuth.config.invitation_expiry + 1.day) do
        _reissued, token = described_class.issue(email: invitee.email)

        expect { described_class.redeem!(token: token, account: invitee) }.not_to raise_error
      end
    end
  end

  # The second door onto the ladder, and a complete one on its own. Seating
  # happens on the invitation's authority, so an invitation nobody was allowed
  # to write satisfies every guard downstream: invite your own address as
  # owner, accept it, and the membership guard has nothing left to object to.
  #
  # The rule used to live in a controller, so it protected one screen. It is
  # asked here now, at the moment the offer is written.
  # What used to be a role ceiling enforced in the engine. SparrowKit no longer
  # ranks roles, so the application states the policy and SparrowKit refuses
  # until it does -- the same property, decided by the only code that can.
  describe "the invitation policy" do
    around do |example|
      previous = SparrowAuth.config.authorize_invitation
      example.run
      SparrowAuth.config.authorize_invitation = previous
    end

    it "refuses every organization invitation when no policy is configured" do
      SparrowAuth.config.authorize_invitation = nil

      expect {
        described_class.issue(email: "friend@example.org", organization: org, role: :viewer, invited_by: boss)
      }.to raise_error(SparrowAuth::InvitationNotAuthorized, /No invitation policy is configured/)
    end

    it "refuses when the policy says no" do
      SparrowAuth.config.authorize_invitation = ->(inviter:, organization:, role:) { false }

      expect {
        described_class.issue(email: "friend@example.org", organization: org, role: :viewer, invited_by: boss)
      }.to raise_error(SparrowAuth::InvitationNotAuthorized, /refused/)
    end

    it "issues when the policy says yes" do
      SparrowAuth.config.authorize_invitation = ->(inviter:, organization:, role:) { true }

      invitation, token = described_class.issue(
        email: "friend@example.org", organization: org, role: :viewer, invited_by: boss
      )

      expect(invitation.role).to eq("viewer")
      expect(token).to be_present
    end

    # The self-escalation path the old ceiling existed to close: invite your own
    # address at a role you should not hold, accept it, and be seated. It is now
    # the policy's job to refuse, and it is handed everything needed to do so.
    it "hands the policy the inviter, the organization and the role" do
      seen = nil
      SparrowAuth.config.authorize_invitation = lambda do |inviter:, organization:, role:|
        seen = {inviter: inviter, organization: organization, role: role}
        false
      end

      expect {
        described_class.issue(email: boss.email, organization: org, role: :owner, invited_by: boss)
      }.to raise_error(SparrowAuth::InvitationNotAuthorized)

      expect(seen).to eq({inviter: boss, organization: org, role: "owner"})
    end
  end
end
