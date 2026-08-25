# frozen_string_literal: true

module SparrowAuth
  module Console
    # What the hub's Authentication card says.
    #
    # Loaded from console_engine.rb, which is itself only required when
    # sparrow_ui is present, so referring to SparrowUi::Console::Settings here
    # is safe in a way it would not be from anywhere else in this gem.
    #
    # Reads the SAME store the panel writes -- the credentials tree, not
    # SparrowAuth.config. A card fed from the live configuration would report a
    # value set in the host's initializer, which the panel neither wrote nor can
    # change, and "Ready" would then be about a different setting than the one
    # the developer is looking at.
    #
    # Returns a plain Hash rather than a SparrowUi::Console::Status: the
    # registry coerces, and keeping the shape dumb means the same method works
    # if this ever has to be read by something that is not the console.
    class Report
      # Without an RP ID there is no Relying Party for a passkey to bind to, so
      # nothing can be enrolled and nothing can be used. It is the one setting
      # on the panel whose absence stops authentication outright.
      # Ready once passkeys have a domain to bind to. That is the only setting
      # here whose absence stops authentication working.
      #
      # The signing key is NOT checked, and used to be: an empty otp_secret
      # produced "Check this -- one-time codes cannot be verified", which was
      # simply false. Rails derives it from the master key when it is blank, and
      # the panel now says in as many words that leaving it blank is right for
      # almost every application.
      #
      # So the card was nagging about the recommended configuration. A badge
      # that says "check this" about the state it just told you to be in is a
      # badge you learn to ignore, and then it is worth nothing on the day it
      # means something -- the same argument that keeps sandbox mode out of
      # sparrow_mail's status.
      #
      # Found by installing the merged code and saving the panel's own defaults.
      def status
        stored = ::SparrowUi::Console::Settings.read(SparrowAuth::CREDENTIALS_KEY)

        # The effective domain, not this gem's own copy. It is inherited from the
        # address on the console's front page unless this panel overrides it, so
        # reading only the override reports a configured application as
        # unconfigured — on the same page that just took the address.
        rp_id = stored[:webauthn_rp_id].presence || SparrowAuth.application_host.to_s
        return unconfigured if rp_id.to_s.empty?

        {state: :ready, detail: "Passkeys bind to #{rp_id}."}
      end

      private

      def unconfigured
        {
          state: :unconfigured,
          detail: "No domain is set for passkeys, so none can be enrolled. " \
                  "Set the application's address on the SparrowKit home page."
        }
      end

      # `attention` and `present?` stood here to report missing signing keys.
      # Both went with that check rather than being left for a future reader to
      # wonder about: this module has two states, and dead code that implies a
      # third is a question somebody has to answer twice.
    end
  end
end
