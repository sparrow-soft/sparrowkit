# frozen_string_literal: true

module SparrowPay
  # Makes an organization the thing that gets billed.
  #
  # Mixed into SparrowAuth::Organization by the engine, so a host never has to
  # wire it and — more to the point — never has the chance to wire it onto an
  # account instead. The organization is the customer and a person is not, and
  # that is settled by there being no other option rather than by a convention
  # somebody has to remember.
  #
  # The reason it matters: a person can belong to several organizations, and
  # they can leave. If the person were the customer, somebody leaving would take
  # the subscription with them, and an organization's access would depend on
  # which of its members happened to have paid.
  #
  # What this does NOT do is keep a copy of what the organization is on. Ask
  # Pay -- `organization.payment_processor.subscribed?`. SparrowKit used to
  # mirror the plan and the status into columns here and keep them current from
  # Pay's webhooks: three columns, two indexes and a state machine, all to avoid
  # asking the library that already knows. Anything cached is a second answer
  # that can be wrong.
  module Billable
    extend ActiveSupport::Concern

    included do
      # Everything to do with a processor comes from here. Pay owns the customer
      # record, the subscriptions, the payment methods and the charges.
      pay_customer

      # The one thing Pay asks the billable model for by name.
      def pay_customer_name = name

      # A rename is a change to what the processor holds, and Pay's own sync
      # does not see it: Pay::Billable::SyncCustomer watches for an email
      # column and nothing else, which an organization does not have. Ours is
      # not that callback either -- see sync_billing_details for why it cannot
      # be.
      after_update_commit :sync_billing_details, if: :saved_change_to_name?
    end

    # The address on the processor's customer record.
    #
    # Pay does not ask the billable model for this the way it asks for a name:
    # Pay::Customer delegates `email` straight to its owner, and every processor
    # -- Stripe, Paddle, Lemon Squeezy, Braintree -- builds its customer from
    # that delegation. So an organization that has no `email` cannot be made
    # into a customer at all; the first attempt raises NoMethodError, and no
    # amount of hooks on this side changes it.
    #
    # This gem shipped such a hook, believed it was being read, and had no test
    # that ever asked Pay to build a customer. Name it what Pay reads.
    def email
      billing_email
    end

    # Where a receipt goes: the account that created the organization, for as
    # long as they own it.
    #
    # An owner rather than whoever set the subscription up, because that person
    # may have left, and the earliest owner rather than any owner, so adding a
    # second one does not move the receipts. `first` on an unordered relation
    # orders by primary key, so this is the founder until ownership actually
    # changes hands.
    #
    # Falls back to the earliest MEMBER -- by membership, not by account -- so
    # an organization mid-handover still has somewhere to send a failed-payment
    # notice, the moment it most needs one. It used to read that off `accounts`,
    # which sorts by account id -- the order people signed up in, not the order
    # they joined -- so a colleague with an older account joining later quietly
    # took over the receipts.
    #
    # `owners` is a scope over memberships, not accounts; reading it as accounts
    # raised on exactly that notice.
    def billing_email
      (owners.first || memberships.first)&.account&.email
    end

    # Push the name and the address to the processor, for a customer that is
    # already there.
    #
    # THE GUARD IS THE POINT. `update_api_record` opens a customer when there is
    # no processor_id -- `api_record unless processor_id?`, in Pay's own code --
    # so a sync that did not check would open an account at the processor for
    # every organization on the system, the first time anybody was seated in
    # one. Only customers that already exist there are updated. Pay's own
    # enqueue does not make this distinction, which is why this does not go
    # through it.
    #
    # Public, because SparrowKit only knows about the ownership changes it can
    # see. An application that decides who pays by some rule of its own calls
    # this after making the change.
    def sync_billing_details
      pay_customers.active.where.not(processor_id: nil).pluck(:id).each do |id|
        Pay::CustomerSyncJob.perform_later(id)
      end
    end
  end
end
