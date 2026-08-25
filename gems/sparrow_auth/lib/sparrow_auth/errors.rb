# frozen_string_literal: true

module SparrowAuth
  class Error < StandardError; end

  # Base class for every refusal to grant access.
  #
  # These raise rather than returning false, throughout. A boolean that nobody
  # checked reads exactly like permission, and every access-control bug found in
  # the portfolio audit had that shape. Code that forgets to ask here does not
  # get a falsy value it can ignore; it gets an exception.
  class AccessError < Error; end

  # The invitation does not exist, has expired, or has already been used. All
  # three are deliberately one error with one message: telling an attacker which
  # of the three it was tells them whether a token they guessed ever existed.
  class InvalidInvitation < AccessError
    def initialize(message = "That invitation link is not valid")
      super
    end
  end

  # The account trying to accept is not the account the invitation was issued
  # to, or its address has never been verified.
  #
  # Both are refused for the same reason. An invitation names an address, and an
  # unverified address is a claim rather than an identity, so accepting on the
  # strength of one would let anyone who registers as the invitee take their
  # place. That is the registration-hijack pattern this engine exists to close.
  # Raised when config.authorize_invitation refuses an invitation, or when no
  # invitation policy has been configured at all.
  class InvitationNotAuthorized < AccessError; end

  class InvitationNotYours < AccessError
    def initialize(message = "That invitation was issued to a different address")
      super
    end
  end

  # A one-time code was refused. Absent, wrong, expired, already used, redeemed
  # under a different request id, or past the attempt cap: all one error with
  # one message, because telling an attacker which wall they hit tells them
  # whether it is worth continuing.
  class InvalidCode < AccessError
    def initialize(message = "That code is not valid")
      super
    end
  end

  # An action needed a verified address and the account does not have one.
  class UnverifiedAccount < AccessError
    def initialize(message = "Verify your email address first")
      super
    end
  end

  # An API token was refused. Absent, wrong, revoked, expired, issued for a
  # different app, or belonging to an account that is no longer usable: all one
  # error with one message, because telling a caller which wall they hit tells
  # them whether the token they presented is a real one.
  class InvalidApiToken < AccessError
    def initialize(message = "That token is not valid")
      super
    end
  end

  # The account is not a member of the organization in question, or its role
  # there does not reach what the action requires.
  #
  # Every refusal inside require_organization! is this one error with this one
  # message: signed out, no organization in scope, no membership, a membership
  # whose stored role is not one we recognise, and a membership that simply does
  # not reach. Telling somebody which of those it was tells them whether the
  # organization exists and whether they are inside it, which is a question they
  # were refused an answer to.
  #
  # `required` and `held` are for the log, where the operator is entitled to the
  # detail the response withholds. They never reach the message.
  class NotAMember < AccessError
    attr_reader :required, :held

    def initialize(message = "You do not have access to that organization", required: nil, held: nil)
      @required = required
      @held = held

      super(message)
    end
  end

  # A role was written without saying who wrote it.
  #
  # Not an AccessError. Nobody was refused -- the code took a path that cannot
  # be checked at all, which is a fault in the application rather than an answer
  # to a request. It must reach an operator as a 500, not a visitor as a 403.
  class UnauthorizedRoleAssignment < Error; end

  # The account may not do this.
  #
  # SparrowAuth never raises this itself -- it does not decide what a role may
  # do. It is here as shared vocabulary, so an application's own authorization
  # rules refuse in the same language as the rest of the engine and one
  # `rescue_from SparrowAuth::AccessError` catches every refusal.
  #
  # Carries what was refused rather than only that something was, because the
  # first question asked of a denial in production is always "which check, on
  # what" -- and reconstructing that from a stack trace is how an afternoon
  # disappears.
  #
  #   raise SparrowAuth::AccessDenied.new(resource: invoice, action: :destroy)
  class AccessDenied < AccessError
    attr_reader :resource, :action, :held_role

    def initialize(resource: nil, action: nil, held_role: nil)
      @resource = resource
      @action = action
      @held_role = held_role

      super(
        if held_role
          "Role #{held_role.inspect} may not #{action || "do this to"} this #{resource.class}"
        else
          "No access to this #{resource.class}"
        end
      )
    end
  end

  # A query against a tenant-scoped model ran with no organization in scope.
  #
  # This is the failure that has to be loud. The alternative to raising is
  # returning every tenant's rows to whoever asked, which looks like a working
  # page right up until someone notices their competitor's data on it.
  class UnscopedQuery < Error
    def initialize(model = nil)
      super(
        "#{model || "A tenant-scoped model"} was queried with no organization in scope. " \
        "Set one with SparrowAuth::Current.organization, or state why this query spans " \
        "tenants with SparrowAuth.across_all_organizations(reason:)."
      )
    end
  end
end
