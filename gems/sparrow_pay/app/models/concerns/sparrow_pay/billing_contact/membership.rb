# frozen_string_literal: true

module SparrowPay
  module BillingContact
    # A seat change moves the receipts, so the processor has to hear about it.
    #
    # Mixed into SparrowAuth::Membership by the engine. The callback belongs
    # here rather than on the organization because the organization row does
    # not change when somebody is seated or leaves -- there is nothing for an
    # `after_update_commit` over there to fire on, which is why the address at
    # the processor used to stay at whoever founded the organization forever.
    #
    # Any seat change syncs, rather than working out whether this particular
    # one moved the address. Deciding that means reconstructing the previous
    # answer from a row that has just been destroyed, and the sync is a single
    # job for a rare event -- and only for an organization that already has a
    # customer at the processor. See SparrowPay::Billable#sync_billing_details.
    module Membership
      extend ActiveSupport::Concern

      included do
        after_commit :sync_billing_contact, on: [:create, :destroy]

        # TWO NAMES, ON PURPOSE. Registering the same method symbol as a second
        # after_commit deletes the first: ActiveSupport's callback chain treats
        # a repeated filter as a duplicate and keeps only the last one, whatever
        # `on:` each was given. Written as one name, this line quietly took the
        # place of the one above it -- seating somebody and removing them both
        # stopped syncing, and only the role change still worked.
        after_commit :sync_billing_contact_for_a_moved_seat, on: :update
      end

      private

      # A role changing is how ownership changes hands, and moving a seat to
      # another account is the same thing said differently. Nothing else on
      # this row is anything the processor holds.
      def sync_billing_contact_for_a_moved_seat
        return unless saved_change_to_role? || saved_change_to_account_id?

        sync_billing_contact
      end

      # Destroying the organization takes its memberships with it by
      # `delete_all`, which runs no callbacks, so this never fires for an
      # organization on its way out.
      def sync_billing_contact
        organization&.sync_billing_details
      end
    end
  end
end
