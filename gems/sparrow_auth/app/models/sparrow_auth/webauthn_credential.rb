# frozen_string_literal: true

module SparrowAuth
  # One enrolled passkey.
  #
  # Rodauth owns these rows during the ceremony — it writes the public key and
  # advances the sign count itself. This is the ActiveRecord view, for the one
  # thing Rodauth has no opinion about: letting a person see what they have
  # enrolled and take one away.
  class WebauthnCredential < ApplicationRecord
    self.table_name = "sparrow_auth_account_webauthn_keys"

    # Composite, because a credential is identified by the pair. Neither the
    # account nor the credential id alone names one row.
    self.primary_key = [:account_id, :webauthn_id]

    belongs_to :account,
      class_name: "SparrowAuth::Account",
      inverse_of: :webauthn_credentials

    validates :nickname, length: {maximum: 64}, allow_nil: true

    scope :oldest_first, -> { order(:created_at) }

    # What to call it in a list. A person with three passkeys needs to tell the
    # laptop from the phone from the one on the machine they no longer own, and
    # the credential itself carries no name — WebAuthn does not provide one.
    def display_name
      nickname.presence || "Passkey added #{created_at.to_date.iso8601}"
    end

    # The credential id is a public identifier, but it is long and opaque, and
    # printing it in full in a UI invites people to compare them by eye. The
    # first few characters are enough to distinguish two rows.
    def short_id
      webauthn_id.to_s[0, 8]
    end

    # Never print the public key or the full credential id. Neither is a secret,
    # but a log line carrying them is a log line that identifies a person's
    # authenticator across every system that ever saw it.
    def inspect
      "#<SparrowAuth::WebauthnCredential account_id=#{account_id} " \
        "id=#{short_id}… nickname=#{nickname.inspect} last_use=#{last_use}>"
    end
    alias_method :to_s, :inspect
  end
end
