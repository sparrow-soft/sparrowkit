# frozen_string_literal: true

module SparrowAuth
  # An account, as the rest of the application sees it.
  #
  # Rodauth writes this table through Sequel; this is the ActiveRecord view of
  # the same rows, for everything that is not an auth ceremony.
  class Account < ApplicationRecord
    self.table_name = "sparrow_auth_accounts"

    # Rodauth's status values. Kept as integers rather than a lookup table
    # because a foreign key to a three-row table buys nothing a check
    # constraint does not.
    UNVERIFIED = 1
    VERIFIED = 2
    CLOSED = 3

    has_many :sent_invitations,
      class_name: "SparrowAuth::Invitation",
      foreign_key: :invited_by_id,
      inverse_of: :invited_by,
      dependent: :nullify

    has_many :memberships,
      class_name: "SparrowAuth::Membership",
      foreign_key: :account_id,
      inverse_of: :account,
      dependent: :destroy

    has_many :organizations, through: :memberships, source: :organization

    has_many :sessions,
      class_name: "SparrowAuth::Session",
      foreign_key: :account_id,
      inverse_of: :account,
      dependent: :delete_all

    has_many :identities,
      class_name: "SparrowAuth::Identity",
      foreign_key: :account_id,
      inverse_of: :account,
      dependent: :delete_all

    has_many :webauthn_credentials,
      class_name: "SparrowAuth::WebauthnCredential",
      foreign_key: :account_id,
      inverse_of: :account,
      dependent: :delete_all

    scope :verified, -> { where(status_id: VERIFIED) }

    # The only question most of this engine asks about an account.
    #
    # An unverified address is a claim that someone typed it, not evidence that
    # they can read mail sent to it. Anything that grants access on the strength
    # of an address has to ask this first.
    def verified?
      status_id == VERIFIED
    end

    def closed?
      status_id == CLOSED
    end

    # Whether this account has a passkey, which is what the enrollment prompt
    # turns on. Asked on page loads, so it counts rather than loading rows.
    def passkey?
      webauthn_credentials.exists?
    end

    def membership_in(organization)
      return nil if organization.nil?

      memberships.find_by(organization_id: organization)
    end

    # Deliberately a question about a specific organization, never a bare
    # `admin?`. There is no such thing as being an admin here in general: the
    # same person may run one tenant and merely belong to another, and a
    # predicate that forgets to ask which one is a permission bug waiting for
    # its second organization to exist.
    def role_in(organization)
      membership_in(organization)&.role
    end

    def member_of?(organization)
      membership_in(organization).present?
    end

    # Raises rather than returning false, like every other access decision in
    # this engine. A falsy value nobody checked reads exactly like permission.
    #
    # Asks one question: does this account belong to this organization? What the
    # membership's role permits is your application's to decide -- SparrowKit
    # does not rank roles and cannot answer it.
    def membership_in!(organization)
      membership = membership_in(organization)
      raise NotAMember if membership.nil?

      membership
    end

    # Addresses are compared case-insensitively everywhere. The column agrees
    # -- citext on PostgreSQL, a NOCASE collation on SQLite -- but callers
    # should not have to know that.
    def self.find_by_email(address)
      find_by(email: address.to_s.strip.downcase)
    end
  end
end
