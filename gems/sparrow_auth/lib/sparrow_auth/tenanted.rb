# frozen_string_literal: true

module SparrowAuth
  # Row-based tenancy for a host application's models.
  #
  #   class Invoice < ApplicationRecord
  #     include SparrowAuth::Tenanted
  #   end
  #
  # Every query is scoped to the organization in scope, and a query made with no
  # organization in scope raises instead of returning rows.
  #
  # Raising is the whole design. The alternative — returning everything when
  # nothing is set — turns one forgotten `where` into a page showing every
  # tenant's data, and that page looks completely normal to whoever built it.
  # The failure has to happen in development, on the first request, not in
  # production on the day a second customer signs up.
  #
  # One honest caveat: Rails' own `unscoped` and `unscope(where: ...)` bypass
  # this, as they bypass any default scope. They are not made safe here and
  # cannot be. What this offers instead is a way to cross tenants that says so
  # out loud — see SparrowAuth.across_all_organizations — and a single term to
  # grep for when reviewing that nobody took the quiet route.
  module Tenanted
    extend ActiveSupport::Concern

    included do
      belongs_to :organization,
        class_name: "SparrowAuth::Organization",
        inverse_of: false

      # This scopes reads *and* stamps writes. A record built inside a scope
      # inherits that scope's where-values as attributes, so a new row belongs
      # to the organization in scope without anybody assigning it — which is the
      # behaviour worth having, since forgetting is otherwise silent: the row
      # saves with no organization and never appears in a scoped query again.
      #
      # An explicit callback to do the same was removed once mutation testing
      # showed the suite could not tell whether it ran.
      default_scope { SparrowAuth::Tenanted.scope_for(self) }
    end

    # Called with the relation being built, so the error names the model that
    # was queried rather than leaving the developer to work it out from a stack
    # trace through ActiveRecord internals.
    def self.scope_for(relation)
      return relation.all if Current.unscoped_reason.present?

      organization = Current.organization
      raise UnscopedQuery, relation.name if organization.nil?

      relation.where(organization_id: organization.id)
    end
  end
end
