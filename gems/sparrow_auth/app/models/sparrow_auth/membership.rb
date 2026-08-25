# frozen_string_literal: true

module SparrowAuth
  # An account's place in an organization.
  #
  # A join row rather than a column on the account, so one person may belong to
  # several organizations. An engine that hard-codes a single tenant cannot be
  # used by the next application, and undoing that later means migrating data
  # and rewriting every query that assumed one.
  #
  # `role` is a name and nothing more. SparrowKit stores it, and your
  # application decides what it means -- there is no ladder here, no ordering,
  # and no notion of one role outranking another. Deciding what a role may do is
  # your code's job, because only your code knows what the roles are.
  class Membership < ApplicationRecord
    self.table_name = "sparrow_auth_memberships"

    belongs_to :account, class_name: "SparrowAuth::Account", inverse_of: :memberships
    belongs_to :organization, class_name: "SparrowAuth::Organization", inverse_of: :memberships

    validates :account_id, uniqueness: {scope: :organization_id}

    scope :with_role, ->(name) { where(role: name.to_s) }

    # Seating somebody an invitation already vouched for.
    #
    # Asserted rather than trusted: an invitation that was never accepted, or
    # was accepted by somebody else, vouches for nothing.
    #
    # NOTE: the authority here is the invitation itself. SparrowKit no longer
    # knows what a role means, so it cannot check that the inviter was entitled
    # to offer the role the invitation names -- see Invitation.issue!. Whoever
    # calls issue! must decide that.
    def self.seat_from_invitation!(invitation)
      account = invitation.accepted_by
      organization = invitation.organization

      raise InvalidInvitation, "That invitation has not been accepted" if invitation.accepted_at.nil?
      raise InvalidInvitation, "That invitation names no organization" if organization.nil?
      raise InvalidInvitation, "That invitation was accepted by somebody else" if account.nil?

      # An invitation is a way in, not a way to change somebody's role. If they
      # are already here, they stay exactly as they are.
      existing = organization.memberships.find_by(account_id: account.id)
      return existing if existing

      create!(organization: organization, account: account, role: invitation.role)
    end
  end
end
