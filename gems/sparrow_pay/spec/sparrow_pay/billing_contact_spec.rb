# frozen_string_literal: true

require "rails_helper"

# Keeping the processor's copy of the billing contact current.
#
# The address is settled in Ruby by SparrowPay::Billable, and the processor
# holds a copy of it from the moment the customer was created. Three things
# move the address afterwards and none of them is an update to the organization
# row: a membership changing hands, the billing account editing its own address,
# and -- for the customer's name rather than its address -- a rename.
RSpec.describe "syncing the billing contact to the processor" do
  before { ActiveJob::Base.queue_adapter = :test }

  def account(email:)
    SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)
  end

  let(:founder) { account(email: "founder@example.org") }
  let(:organization) { SparrowAuth::Organization.create_with_owner!(account: founder, name: "Acme") }

  # An organization that has already been through checkout: a customer exists
  # at the processor, with an id to update.
  def paying(organization)
    organization.set_payment_processor(:fake_processor, allow_fake: true)
    organization.payment_processor.update!(processor_id: "cus_#{organization.slug}")
    organization.payment_processor
  end

  def seat(email, role)
    organization.memberships.create!(account: account(email: email), role: role)
  end

  describe "an organization that has never paid" do
    # Pay's update creates the customer when there is no processor_id -- see
    # Pay::Stripe::Customer#update_api_record. Syncing indiscriminately would
    # therefore open an account at the processor for every organization on the
    # system, the first time anybody was seated in one.
    it "is never sent to the processor when it has no customer at all" do
      organization

      expect { seat("second@example.org", "owner") }
        .not_to have_enqueued_job(Pay::CustomerSyncJob)
    end

    it "is never sent to the processor when its customer has no id there" do
      organization.set_payment_processor(:fake_processor, allow_fake: true)

      expect { seat("second@example.org", "owner") }
        .not_to have_enqueued_job(Pay::CustomerSyncJob)
    end
  end

  describe "an organization that pays" do
    it "syncs when the founder's membership goes" do
      customer = paying(organization)
      seat("second@example.org", "owner")

      expect { organization.membership_for(founder).destroy }
        .to have_enqueued_job(Pay::CustomerSyncJob).with(customer.id)
    end

    it "syncs when somebody is seated" do
      customer = paying(organization)

      expect { seat("second@example.org", "owner") }
        .to have_enqueued_job(Pay::CustomerSyncJob).with(customer.id)
    end

    it "syncs when a role changes hands" do
      customer = paying(organization)
      membership = seat("second@example.org", "reviewer")

      expect { membership.update!(role: "owner") }
        .to have_enqueued_job(Pay::CustomerSyncJob).with(customer.id)
    end

    # The name Pay sends is the organization's. Pay's own predicate watches for
    # an email column and nothing else, so a rename reached nobody.
    it "syncs when the organization is renamed" do
      customer = paying(organization)

      expect { organization.update!(name: "Acme Holdings") }
        .to have_enqueued_job(Pay::CustomerSyncJob).with(customer.id)
    end

    it "does not sync when nothing the processor holds has changed" do
      paying(organization)

      expect { organization.touch }.not_to have_enqueued_job(Pay::CustomerSyncJob)
    end
  end

  describe "an account changing its own address" do
    it "syncs the organizations it is billed for" do
      customer = paying(organization)

      expect { founder.update!(email: "moved@example.org") }
        .to have_enqueued_job(Pay::CustomerSyncJob).with(customer.id)
    end

    # A person can be in several organizations and is the billing contact for
    # few of them.
    it "leaves alone an organization it is only a member of" do
      paying(organization)
      colleague = account(email: "colleague@example.org")
      organization.memberships.create!(account: colleague, role: "reviewer")

      expect { colleague.update!(email: "colleague@example.com") }
        .not_to have_enqueued_job(Pay::CustomerSyncJob)
    end
  end
end
