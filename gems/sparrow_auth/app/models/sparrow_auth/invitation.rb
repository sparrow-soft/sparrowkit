# frozen_string_literal: true

require "securerandom"
require "openssl"

module SparrowAuth
  # An invitation to an address.
  #
  # The security of this comes down to one sentence: an invitation names an
  # address, and only an account that has *proved* it can read mail at that
  # address may accept it. Everything below is in service of that.
  #
  # The shape follows an application this was drawn from, which got the hard
  # parts right, with one addition its audit found missing. That one checked
  # that the accepting
  # account's address matched, but never that the address had been verified, so
  # registering as the invitee and never confirming the address was enough to
  # take their place. #redeem! refuses that.
  class Invitation < ApplicationRecord
    self.table_name = "sparrow_auth_invitations"

    belongs_to :invited_by,
      class_name: "SparrowAuth::Account",
      optional: true,
      inverse_of: :sent_invitations

    belongs_to :accepted_by,
      class_name: "SparrowAuth::Account",
      optional: true

    # Optional, and the default. An invitation that names no organization is an
    # invitation to the product, and what happens on acceptance is the host's
    # after_invitation_accepted hook. One that names an organization is an
    # invitation to join it, and the engine seats them itself — see #redeem!.
    belongs_to :organization,
      class_name: "SparrowAuth::Organization",
      optional: true,
      inverse_of: :invitations

    scope :pending, -> { where(accepted_at: nil).where(arel_table[:expires_at].gt(Time.current)) }
    scope :for_organization, ->(organization) { where(organization_id: organization&.id) }
    scope :newest_first, -> { order(created_at: :desc) }

    validate :role_needs_an_organization

    TOKEN_BYTES = 32

    class << self
      # Issues an invitation and returns it with the token, which is the only
      # time the token exists in readable form. What is stored is a digest, so a
      # database backup is not a bag of working invitation links.
      #
      # Any earlier pending invitation to the same address is superseded rather
      # than left alongside. Two live links to one address means revoking one
      # accomplishes nothing.
      # An invitation naming an organization must say who is offering it and
      # what they are offering, and the offer is checked against the inviter's
      # own standing before the row exists.
      #
      # Without that check this class is a second way to climb the ladder, and a
      # complete one: the membership guard cannot help, because seating happens
      # on the invitation's authority and the invitation is what would be
      # forged. Invite your own address as owner, accept it, and every guard
      # downstream is satisfied by a row that should never have been written.
      #
      # The comment on this class has described that attack since it was
      # written. The rule lived in a controller instead, so it protected one
      # screen rather than the model, and the screen is gone.
      #
      # `role` has no default when an organization is named. Deny by default
      # means the offer is stated, not inherited from a fallback.
      def issue(email:, invited_by: nil, expires_in: nil, organization: nil, role: nil)
        check_the_invitation_ceiling!(organization: organization, role: role, invited_by: invited_by)

        address = normalize_email(email)
        token = SecureRandom.urlsafe_base64(TOKEN_BYTES)

        invitation = transaction do
          # Superseded within the same context only. An invitation to join one
          # organization must not cancel an invitation to join another: they are
          # different offers to the same person, and revoking one by issuing the
          # other would be a surprise nobody asked for.
          #
          # These three conditions are exactly the key of the unique indexes on
          # this table, and they have to stay exactly that. The indexes cover
          # `accepted_at IS NULL` — which an *expired* invitation still
          # satisfies — so anything this clears less of survives, keeps its slot,
          # and is invisible: `pending` filters it out of every list, no screen
          # can revoke what it cannot show, and the next invitation to that
          # address raises RecordNotUnique in the caller's face.
          #
          # That is not hypothetical. Two columns naming an invited resource
          # were once part of this clause and no part of the index, and an
          # invitation to a project inside an organization permanently blocked
          # inviting the same person to the organization itself. The columns are
          # gone; the rule that put them there is worth keeping.
          where(email: address, accepted_at: nil, organization_id: organization&.id).delete_all

          create!(
            email: address,
            token_digest: digest(token),
            invited_by: invited_by,
            organization: organization,
            role: role&.to_s,
            expires_at: Time.current + (expires_in || SparrowAuth.config.invitation_expiry)
          )
        end

        [invitation, token]
      end

      # Issues an invitation and sends it.
      #
      # Delivery is deliberately outside the transaction that created the row.
      # An external call inside a transaction holds a database connection open
      # for the length of someone else's outage, and the audit that shaped this
      # engine found exactly that pattern. The invitation exists either way; a
      # provider being down must not undo a grant that was already made.
      # The same ceiling applies: this is `issue` plus delivery.
      def invite!(email:, url_builder:, invited_by: nil, organization: nil, role: nil)
        invitation, token = issue(
          email: email, invited_by: invited_by, organization: organization, role: role
        )

        Mailer.invitation(
          email: invitation.email,
          url: url_builder.call(token),
          invited_by: invited_by&.email
        ).deliver_now

        [invitation, token]
      end

      # The invitation a token names, or nil.
      #
      # PUBLIC, and it has to be. The screen somebody lands on from an
      # invitation email has to show them what they are being invited to before
      # they accept it -- which organization, by whom -- and the token is the
      # only thing they arrive holding. `digest` is private and should stay
      # that way, so without this a buyer cannot make that page at all.
      #
      # `rails generate sparrowkit:screens invitation` wrote a page calling this
      # method for a release in which it did not exist, so the generated screen
      # raised NoMethodError on its first visit. Caught by bin/smoke driving the
      # generated pages rather than the engine's deleted ones.
      #
      # It AUTHORISES NOTHING. It answers "which invitation is this", not "may
      # you have it" -- the caller still has to ask `pending?`, and accepting
      # goes through redeem!, which checks the address and the account's
      # verification for itself. A lookup that quietly refused would tempt
      # somebody to treat a non-nil return as permission.
      def find_by_token(token)
        find_by(token_digest: digest(token.to_s))
      end

      # Accepts an invitation, or raises. Never returns a boolean: a falsy
      # return that nobody checked reads exactly like permission, and that is
      # the shape of every access-control bug the portfolio audit found.
      def redeem!(token:, account:)
        invitation = find_by(token_digest: digest(token.to_s))

        # One error for absent, expired and already-used. Distinguishing them
        # tells an attacker whether a token they guessed ever existed.
        raise InvalidInvitation unless invitation&.pending?

        # The whole point. The address must match, and the account must have
        # proved it can read mail there. An unverified address is a claim.
        raise InvitationNotYours unless invitation.claimable_by?(account)

        # Conditional update, so two clicks on one link land here concurrently
        # and the second one is a no-op rather than a second grant.
        claimed = where(id: invitation.id, accepted_at: nil)
          .update_all(accepted_at: Time.current, accepted_by_id: account.id)

        raise InvalidInvitation if claimed.zero?

        invitation.reload.tap do |accepted|
          accepted.seat_in_organization(account)
          SparrowAuth.run_hook(:after_invitation_accepted, account, accepted)
        end
      end

      def normalize_email(email)
        email.to_s.strip.downcase
      end

      # SHA-256 rather than bcrypt, deliberately. A 256-bit random token has no
      # guessable structure, so there is nothing for a slow hash to defend
      # against, and lookup has to be by digest rather than by trying every row.
      # Whether this invitation may be issued at all.
      #
      # SparrowKit does not know what your roles mean, so it cannot decide this
      # for you -- and the decision matters more here than anywhere else. An
      # invitation grants whatever role it names, and seating happens on the
      # invitation's authority, so the membership guard cannot help: the
      # invitation is the thing that would be forged. Without a check here,
      # anybody who can reach this method may invite their own address as any
      # role, accept it, and be seated at that role with every guard downstream
      # satisfied by a row that should never have been written.
      #
      # So the application decides, through config.authorize_invitation, and
      # the default is to refuse. That way the failure lands the first time
      # somebody issues an invitation in development, rather than the first time
      # somebody escalates in production.
      #
      # An invitation to the product -- no organization -- carries no role and
      # needs no actor, so it is left alone.
      def check_the_invitation_ceiling!(organization:, role:, invited_by:)
        return if organization.nil?

        if invited_by.nil?
          raise ArgumentError,
            "An invitation into an organization has to say who is offering it: " \
            "invited_by:. Without an inviter there is nothing to authorize."
        end

        if role.blank?
          raise ArgumentError,
            "An invitation into an organization has to name the role it offers. " \
            "There is deliberately no default: an offer nobody stated is an " \
            "offer nobody reviewed."
        end

        authorize = SparrowAuth.config.authorize_invitation

        if authorize.nil?
          raise InvitationNotAuthorized,
            "No invitation policy is configured, so SparrowKit refuses to issue " \
            "this one. Set config.authorize_invitation to a callable taking " \
            "(inviter:, organization:, role:) and returning true when that " \
            "person may offer that role in that organization."
        end

        return if authorize.call(inviter: invited_by, organization: organization, role: role.to_s)

        raise InvitationNotAuthorized,
          "config.authorize_invitation refused this invitation."
      end

      def digest(token)
        OpenSSL::Digest::SHA256.hexdigest(token.to_s)
      end
    end

    def pending?
      accepted_at.nil? && expires_at.present? && expires_at > Time.current
    end

    def accepted?
      accepted_at.present?
    end

    # Whether this account may accept, and the only place that decision is made.
    #
    # Three conditions, all required. The address must match, which stops a
    # forwarded link being a grant. The account must be verified, which stops
    # registering as the invitee being a grant. And the account must not be
    # closed, because a closed account is not an identity anyone should be able
    # to act through.
    def claimable_by?(account)
      return false if account.nil?
      return false unless account.verified?
      return false if account.closed?

      self.class.normalize_email(account.email) == self.class.normalize_email(email)
    end

    # Joining the organization the invitation named, at the role it named.
    #
    # Only ever called from #redeem!, after the address has been matched and the
    # account's verification confirmed — the membership is created on the
    # strength of those checks and no others.
    #
    # An existing membership is left exactly as it is. An invitation is a way in,
    # not a way to change the role of somebody already inside: honouring the
    # named role here would let anyone who can send an invitation demote an
    # owner, or promote themselves by inviting their own address.
    def seat_in_organization(account)
      return if organization_id.nil?

      Membership.seat_from_invitation!(self)
    end

    # Invitations carry a live token. Nothing here prints it, and the digest is
    # not printed either, because a digest plus a known token format is a
    # confirmation oracle.
    def role_needs_an_organization
      return if role.blank? || organization_id.present?

      errors.add(:role, "means nothing without an organization to hold it in")
    end

    def inspect
      "#<SparrowAuth::Invitation id=#{id} email=#{email.inspect} " \
        "pending=#{pending?} expires_at=#{expires_at} token=[never stored]>"
    end
    alias_method :to_s, :inspect
  end
end
