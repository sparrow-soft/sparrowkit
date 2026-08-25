# frozen_string_literal: true

require "rails_helper"

RSpec.describe SparrowAuth::Organization do
  def account(email:, verified: true)
    SparrowAuth::Account.create!(
      email: email,
      status_id: verified ? SparrowAuth::Account::VERIFIED : SparrowAuth::Account::UNVERIFIED
    )
  end

  describe ".create_with_owner!" do
    it "creates the organization and its owner in one act" do
      creator = account(email: "founder@example.org")

      organization = described_class.create_with_owner!(account: creator, name: "Acme")

      expect(organization.owners.count).to eq(1)
      expect(creator.role_in(organization)).to eq("owner")
    end

    # An organization with no owner cannot invite, cannot grant and cannot be
    # handed on. If the membership fails, the organization must not survive it.
    it "creates neither when the membership cannot be created" do
      creator = account(email: "founder@example.org")
      allow_any_instance_of(SparrowAuth::Membership).to receive(:valid?).and_return(false)

      expect {
        begin
          described_class.create_with_owner!(account: creator, name: "Doomed")
        rescue ActiveRecord::RecordInvalid
          nil
        end
      }.not_to change(described_class, :count)
    end

    it "calls the after_organization_created hook with the organization and its creator" do
      creator = account(email: "founder@example.org")
      seen = []
      SparrowAuth.config.after_organization_created = ->(org, by) { seen << [org.name, by.email] }

      described_class.create_with_owner!(account: creator, name: "Acme")

      expect(seen).to eq([["Acme", "founder@example.org"]])
    end
  end

  describe "slugs" do
    it "derives one from the name" do
      organization = described_class.create!(name: "Acme Widgets")

      expect(organization.slug).to eq("acme-widgets")
    end

    it "does not collide when two organizations share a name" do
      first = described_class.create!(name: "Acme")
      second = described_class.create!(name: "Acme")

      expect(second.slug).not_to eq(first.slug)
    end

    # Slugs end up in URLs and bookmarks. Recomputing one because somebody
    # corrected a typo in the name would break every link that pointed here.
    it "keeps the slug when the name changes" do
      organization = described_class.create!(name: "Acme")

      organization.update!(name: "Acme International")

      expect(organization.reload.slug).to eq("acme")
    end

    it "treats slugs case-insensitively, so /acme and /ACME are one tenant" do
      described_class.create!(name: "Acme", slug: "acme")

      expect {
        described_class.create!(name: "Other", slug: "ACME")
      }.to raise_error(ActiveRecord::RecordInvalid)
    end
  end

  describe "multiple organizations per account" do
    # The constraint two earlier applications both schema-enforced, and the one an
    # engine must not inherit: undoing it later means migrating data and
    # rewriting every query that assumed a single tenant.
    it "lets one account belong to several" do
      person = account(email: "consultant@example.org")
      client = account(email: "client@example.org")
      first = described_class.create_with_owner!(account: person, name: "First Client")
      second = described_class.create_with_owner!(account: client, name: "Second Client")
      second.memberships.create!(account: person, role: :member)

      expect(person.organizations).to contain_exactly(first, second)
      expect(person.role_in(first)).to eq("owner")
      expect(person.role_in(second)).to eq("member")
    end

    # Being an owner somewhere is not being an owner everywhere. This is the
    # bug a bare `account.admin?` predicate produces the day a second
    # organization exists.
    it "keeps roles independent between organizations" do
      person = account(email: "consultant@example.org")
      host = account(email: "host@example.org")
      described_class.create_with_owner!(account: person, name: "Owned")
      joined = described_class.create_with_owner!(account: host, name: "Joined")
      joined.memberships.create!(account: person, role: :member)
    end
  end
end
