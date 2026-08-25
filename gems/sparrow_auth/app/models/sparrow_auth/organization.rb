# frozen_string_literal: true

module SparrowAuth
  # A tenant.
  #
  # Small on purpose. This row is identity — a name, a handle, and who belongs
  # to it — and nothing else. Applications keep their own settings in their own
  # tables, because an engine that guessed which settings every application
  # needs would be wrong for all of them and immovable afterwards.
  class Organization < ApplicationRecord
    self.table_name = "sparrow_auth_organizations"

    # delete_all rather than destroy, so destroying an organization does not run
    # the guard that stops its last owner from leaving. That guard exists to
    # keep a *surviving* organization administrable; applied to one being
    # deleted it would make the organization impossible to delete at all.
    has_many :memberships,
      class_name: "SparrowAuth::Membership",
      foreign_key: :organization_id,
      inverse_of: :organization,
      dependent: :delete_all

    has_many :accounts, through: :memberships, source: :account

    # Deleted with the organization by the foreign key rather than by Rails, so
    # a console `delete_all` cannot leave a live invitation pointing at an
    # organization that no longer exists.
    has_many :invitations,
      class_name: "SparrowAuth::Invitation",
      foreign_key: :organization_id,
      inverse_of: :organization,
      dependent: nil

    validates :name, presence: true
    validates :slug, presence: true, uniqueness: {case_sensitive: false}

    before_validation :derive_slug, on: :create

    scope :for_account, ->(account) {
      joins(:memberships).where(sparrow_auth_memberships: {account_id: account})
    }

    # Creating an organization and giving it an owner is one act, not two.
    #
    # An organization with no owner is a tenant nobody can administer: it cannot
    # invite, cannot grant, and cannot be handed to anyone, and the only way out
    # is a console. Rolling both into one transaction means that state never
    # exists, not even briefly.
    # Creates an organization and seats its first member.
    #
    # `role:` is a name your application chooses; "owner" is only a default.
    # This is the one seating with nobody to authorize it against, because there
    # are no members yet -- which is safe only while the organization really is
    # empty, so it is asserted rather than assumed. The assertion is what stops
    # this being called later, on a populated organization, to seat somebody
    # around whatever policy config.authorize_invitation applies.
    def self.create_with_owner!(account:, role: "owner", **attributes)
      organization = nil

      transaction do
        organization = create!(**attributes)

        if organization.memberships.exists?
          raise UnauthorizedRoleAssignment,
            "create_with_owner! is for an organization with no members. " \
            "Invite somebody instead to add them to one that has them."
        end

        organization.memberships.create!(account: account, role: role.to_s)
      end

      SparrowAuth.run_hook(:after_organization_created, organization, account)
      organization
    end

    # Organizations are addressed by slug, not by id.
    #
    # The engine's own routes say so (`param: :slug`), and without this every
    # path helper would quietly interpolate the id instead — producing URLs that
    # look right, resolve to nothing, and are then refused as though the caller
    # had no access. A slug is validated present and unique, so it is a safe
    # identifier; an id in a URL is also a count of how many customers there are.
    def to_param
      slug
    end

    def membership_for(account)
      return nil if account.nil?

      memberships.find_by(account_id: account)
    end

    def owners
      memberships.where(role: "owner")
    end

    private

    # A handle derived once, at creation, and never recomputed. Slugs end up in
    # URLs and in people's bookmarks; silently changing one because somebody
    # corrected a typo in the name would break every link that pointed here.
    def derive_slug
      return if slug.present?

      base = name.to_s.parameterize
      base = "org" if base.empty?

      candidate = base
      suffix = 2

      while self.class.where(slug: candidate).exists?
        candidate = "#{base}-#{suffix}"
        suffix += 1
      end

      self.slug = candidate
    end
  end
end
