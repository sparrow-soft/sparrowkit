# frozen_string_literal: true

module SparrowAuth
  # Controller-level resolution of who is asking and which tenant they are in.
  #
  #   class ApplicationController < ActionController::Base
  #     include SparrowAuth::Tenancy
  #   end
  #
  # After this, `current_organization` is set for the request and every
  # SparrowAuth::Tenanted model is scoped to it.
  module Tenancy
    extend ActiveSupport::Concern

    included do
      before_action :establish_sparrow_auth_context

      helper_method :current_account, :current_organization if respond_to?(:helper_method)
    end

    private

    # One lookup, and the organization is only accepted if it came back with a
    # membership attached.
    #
    # It used to take whatever resolve_current_organization returned. The two
    # built-in paths both reach the organization *through* a membership, so that
    # was safe -- but a host's own organization_for_request does not, and a
    # subdomain rule returning an organization the account does not belong
    # to would put it in request scope, and the application's own authorization
    # rule might never think to check -- so an action that only asked "is this
    # user signed in?" would serve the wrong tenant's rows.
    #
    # Confirming the membership here means there is no state in which an
    # organization is in scope that the current account does not belong to. It
    # also makes current_membership free, which is what the authorization check
    # then asks.
    #
    # If you genuinely need a per-tenant page for somebody who is not a member,
    # say so where a reviewer can see it:
    #
    #   SparrowAuth::Current.with_organization(organization) { ... }
    def establish_sparrow_auth_context
      Current.account = current_account
      @sparrow_auth_membership = membership_for_the_requested_organization
      Current.organization = @sparrow_auth_membership&.organization
    end

    # The membership this request is acting under, or nil. Set by the
    # before_action above; read by the application's own authorization rules.
    attr_reader :sparrow_auth_membership

    def membership_for_the_requested_organization
      return nil if current_account.nil?

      candidate = requested_organization
      return nil if candidate.nil?

      current_account.membership_in(candidate)
    end

    def current_account
      return @current_account if defined?(@current_account)

      @current_account = rodauth.rails_account
    end

    def current_organization
      Current.organization
    end

    # Which organization this request is *asking* for. Whether the account may
    # have it is decided above, not here.
    def requested_organization
      configured = SparrowAuth.config.organization_for_request
      return configured.call(self) if configured

      organization_from_session || only_organization_of_current_account
    end

    # Re-read from the membership table on every request, never trusted from the
    # session alone.
    #
    # The session holds an id, which is a record of what somebody chose, not
    # evidence they may still have it. Memberships are revoked; if this trusted
    # the stored id, revoking somebody's access would leave them inside the
    # tenant until they happened to sign out. Looking it up through the account's
    # own memberships means revocation takes effect on the next request.
    def organization_from_session
      chosen = session[:sparrow_auth_organization_id]
      return nil if chosen.blank? || current_account.nil?

      current_account.memberships.find_by(organization_id: chosen)&.organization
    end

    # Somebody who belongs to exactly one organization is in it. Somebody who
    # belongs to several is in none until they say which, because choosing on
    # their behalf is how a person writes into the wrong tenant while believing
    # they were somewhere else. Two rows are enough to know which case this is.
    def only_organization_of_current_account
      return nil if current_account.nil?

      memberships = current_account.memberships.limit(2).to_a
      return nil unless memberships.size == 1

      memberships.first.organization
    end

    # Changing tenants is an access decision, so it is checked like one and
    # raises like one.
    #
    # Membership is the whole requirement. It used to demand :member, which
    # refused a viewer entry to an organization they legitimately belong to --
    # a rank test standing in for an existence test.
    def switch_organization!(organization)
      membership = current_account&.membership_in(organization)
      raise NotAMember if membership.nil? || membership.role.nil?

      session[:sparrow_auth_organization_id] = organization.id
      @sparrow_auth_membership = membership
      Current.organization = organization
    end
  end
end
