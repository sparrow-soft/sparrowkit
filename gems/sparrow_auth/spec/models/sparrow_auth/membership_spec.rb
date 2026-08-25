# frozen_string_literal: true

require "rails_helper"

RSpec.describe SparrowAuth::Membership do
  def account(email:)
    SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)
  end

  let(:founder) { account(email: "founder@example.org") }
  let(:organization) { SparrowAuth::Organization.create_with_owner!(account: founder, name: "Acme") }

  # Roles are plain names now. SparrowKit stores one and the application decides
  # what it means, so seating somebody is an ordinary create with no ceiling to
  # clear -- see the note on SparrowAuth::Membership.
  def seat(email, role)
    organization.memberships.create!(account: account(email: email), role: role)
  end

  it "links an account to an organization" do
    membership = seat("someone@example.org", "viewer")

    expect(membership.account.email).to eq("someone@example.org")
    expect(membership.organization).to eq(organization)
    expect(membership.role).to eq("viewer")
  end

  it "seats the founder of a new organization" do
    expect(organization.memberships.count).to eq(1)
    expect(organization.memberships.sole.account).to eq(founder)
    expect(organization.memberships.sole.role).to eq("owner")
  end

  it "takes the role name the caller chooses, without interpreting it" do
    expect(seat("odd@example.org", "inventory_manager").role).to eq("inventory_manager")
  end

  it "refuses a second membership for the same account in one organization" do
    person = account(email: "twice@example.org")
    organization.memberships.create!(account: person, role: "viewer")

    duplicate = organization.memberships.new(account: person, role: "admin")

    expect(duplicate).not_to be_valid
  end

  it "finds memberships by role name" do
    seat("viewer@example.org", "viewer")

    expect(described_class.with_role("viewer").count).to eq(1)
    expect(described_class.with_role(:viewer).count).to eq(1)
    expect(described_class.with_role("owner").count).to eq(1)
  end

  describe ".seat_from_invitation!" do
    let(:invitee) { account(email: "invitee@example.org") }

    def invitation(accepted_by: invitee, accepted: true, organization: self.organization)
      SparrowAuth::Invitation.create!(
        email: "invitee@example.org",
        organization: organization,
        invited_by: founder,
        role: organization.nil? ? nil : "viewer",
        token_digest: SecureRandom.hex(32),
        expires_at: 1.week.from_now,
        accepted_at: accepted ? Time.current : nil,
        accepted_by: accepted ? accepted_by : nil
      )
    end

    it "seats the account the invitation was accepted by, at the role it named" do
      membership = described_class.seat_from_invitation!(invitation)

      expect(membership.account).to eq(invitee)
      expect(membership.organization).to eq(organization)
      expect(membership.role).to eq("viewer")
    end

    it "refuses an invitation nobody has accepted" do
      expect { described_class.seat_from_invitation!(invitation(accepted: false)) }
        .to raise_error(SparrowAuth::InvalidInvitation, /not been accepted/)
    end

    it "refuses an invitation naming no organization" do
      expect { described_class.seat_from_invitation!(invitation(organization: nil)) }
        .to raise_error(SparrowAuth::InvalidInvitation, /names no organization/)
    end

    # An invitation is a way in, not a way to change somebody's role.
    it "leaves an existing member exactly as they are" do
      existing = organization.memberships.create!(account: invitee, role: "admin")

      expect(described_class.seat_from_invitation!(invitation)).to eq(existing)
      expect(existing.reload.role).to eq("admin")
    end
  end
end
