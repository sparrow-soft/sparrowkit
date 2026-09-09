# frozen_string_literal: true

module SparrowPay
  module BillingContact
    # Somebody correcting their own address, where they are the one being
    # billed.
    #
    # Mixed into SparrowAuth::Account by the engine. An organization borrows
    # this address rather than holding one, so the change that matters to the
    # processor happens on a row the organization knows nothing about.
    #
    # Only the organizations this account is actually billed for. A person can
    # belong to several and is the billing contact for few of them, and
    # `billing_email` is the one thing that says which -- asked per
    # organization rather than assumed from the role, so it stays right if the
    # rule for choosing the address ever changes.
    module Account
      extend ActiveSupport::Concern

      included do
        after_update_commit :sync_billing_contact, if: :saved_change_to_email?
      end

      private

      def sync_billing_contact
        organizations.each do |organization|
          organization.sync_billing_details if organization.billing_email == email
        end
      end
    end
  end
end
