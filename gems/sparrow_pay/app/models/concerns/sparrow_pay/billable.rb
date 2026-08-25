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

      # Pay asks the billable model for these two. An organization has no email
      # of its own, so it borrows an owner's — which is what a receipt should be
      # addressed to, and which changes correctly when ownership does.
      def pay_customer_name = name
      def pay_customer_email = billing_email
    end

    # Where a receipt goes.
    #
    # An owner rather than whoever set the subscription up, because that person
    # may have left. Falls back to any member so an organization mid-handover
    # still has somewhere to send a failed-payment notice — the moment it most
    # needs one.
    #
    # `owners` is a scope over memberships, not accounts; reading it as accounts
    # raised on exactly that notice.
    def billing_email
      owners.first&.account&.email || accounts.first&.email
    end
  end
end
