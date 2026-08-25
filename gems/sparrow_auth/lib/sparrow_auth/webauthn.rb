# frozen_string_literal: true

module SparrowAuth
  # The relying party this application is, for ceremonies the engine drives
  # itself rather than handing to Rodauth.
  #
  # There is exactly one of these and it must agree with Rodauth's *exactly*. A
  # credential is bound to an RP ID at enrolment and will not verify against a
  # different one, so a disagreement here does not degrade gracefully — every
  # passkey stops working, and the fix is asking everybody to enrol again.
  #
  # So both read the same three settings, and both fall back the same way:
  # Rodauth derives the origin from the request and the RP ID by stripping the
  # scheme and port off it. spec/requests/staff_step_up_spec.rb enrols through
  # Rodauth's own form and then verifies through this, which is the only test
  # that can actually prove the two agree.
  module Webauthn
    class << self
      def relying_party(request)
        origin = SparrowAuth.config.webauthn_origin || request.base_url

        ::WebAuthn::RelyingParty.new(
          origin: origin,
          id: SparrowAuth.config.webauthn_rp_id || rp_id_from(origin),
          name: SparrowAuth.config.webauthn_rp_name || request.host
        )
      end

      # Rodauth's own derivation: the origin with the scheme and any port
      # removed. Reproduced rather than called, because reaching into a Rodauth
      # instance from a Rails controller to ask would couple this to the shape
      # of a request Rodauth may not be handling.
      def rp_id_from(origin)
        URI(origin).host.to_s
      rescue URI::InvalidURIError
        origin.to_s.sub(%r{\Ahttps?://}, "").sub(/:\d+\z/, "")
      end
    end
  end
end
