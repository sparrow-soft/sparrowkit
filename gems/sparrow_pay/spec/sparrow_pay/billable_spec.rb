# frozen_string_literal: true

require "rails_helper"

# Asserted against Pay's own customer object, not against our own methods.
#
# This gem defined an email hook of its own and trusted that Pay asked for it.
# Pay asks the billable model for a name and reads `owner.email` directly --
# Pay::Customer delegates it -- so every processor raised NoMethodError on the
# first attempt to create a customer, and nothing here noticed, because nothing
# here had ever asked Pay to build one. A test that calls our method proves
# only that our method works.
RSpec.describe SparrowPay::Billable do
  def account(email:)
    SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)
  end

  let(:founder) { account(email: "founder@example.org") }
  let(:organization) { SparrowAuth::Organization.create_with_owner!(account: founder, name: "Acme") }

  def seat(email, role)
    organization.memberships.create!(account: account(email: email), role: role)
  end

  # Exactly what Pay sends the processor when it creates the customer.
  def customer_attributes
    Pay::Stripe::Customer.new(owner: organization, processor: "stripe").api_record_attributes
  end

  it "gives the processor the organization's name and an address for its receipts" do
    expect(customer_attributes).to eq(email: "founder@example.org", name: "Acme")
  end

  it "bills a new organization to the account that created it" do
    expect(organization.email).to eq("founder@example.org")
    expect(organization.billing_email).to eq("founder@example.org")
  end

  # `first` on an unordered relation orders by primary key, so the earliest
  # owner is the founder and stays the founder while they hold the role.
  it "keeps the founder's address when a second owner joins later" do
    seat("second@example.org", "owner")

    expect(organization.billing_email).to eq("founder@example.org")
  end

  it "moves to the next owner when the founder's membership goes" do
    seat("second@example.org", "owner")
    organization.membership_for(founder).destroy

    expect(organization.reload.billing_email).to eq("second@example.org")
  end

  # `owners` matches the literal string "owner", which an application is free
  # not to use. Falling back to the earliest MEMBER keeps a receipt going to
  # whoever set the organization up rather than to whoever signed up first --
  # an older account joining later must not take the receipts.
  it "falls back to the founder when no membership is called owner" do
    veteran = account(email: "veteran@example.org")
    latecomer = account(email: "latecomer@example.org")
    organization = SparrowAuth::Organization.create_with_owner!(
      account: latecomer, name: "Globex", role: "principal"
    )
    organization.memberships.create!(account: veteran, role: "principal")

    expect(organization.billing_email).to eq("latecomer@example.org")
  end

  it "has no address when the organization has no members left" do
    organization.memberships.delete_all

    expect(organization.reload.billing_email).to be_nil
  end
end
