# frozen_string_literal: true

require "openssl"
require "securerandom"

module SparrowAuth
  # A six-digit code emailed to an address, redeemable once, from one browser.
  #
  # The flow comes from an application this was drawn from, which was audited
  # and mostly got it right, with its fix list applied. What it got right and is
  # kept: rejection sampling so
  # the codes are uniform, an HMAC digest keyed on a dedicated secret rather
  # than the code itself, constant-time comparison, an opaque request id bound
  # to the browser by a cookie, an attempt cap that destroys the row.
  #
  # Three things are secrets of different kinds and are deliberately not
  # interchangeable. The code is what the person knows. The request id is what
  # their browser holds. The digest is what we store. Holding any one of them
  # is not enough to redeem anything.
  class OneTimeCode < ApplicationRecord
    self.table_name = "sparrow_auth_otp_codes"

    DIGITS = 6
    CODE_SPACE = 10**DIGITS
    LIFETIME = 10.minutes
    MAX_ATTEMPTS = 5

    # The largest multiple of the code space that fits in 32 bits. Draws at or
    # above it are thrown away and redrawn, which is what makes every code
    # equally likely. Taking a 32-bit draw modulo a million instead would make
    # the low codes fractionally more likely: a small bias, and an avoidable one.
    SAMPLE_CEILING = (2**32 / CODE_SPACE) * CODE_SPACE

    class << self
      def generate_code
        loop do
          draw = SecureRandom.random_number(2**32)
          next if draw >= SAMPLE_CEILING

          # Zero-padded, because the code someone reads out of an email is a
          # string of six characters and "004821" must not be checked as 4821.
          return format("%0#{DIGITS}d", draw % CODE_SPACE)
        end
      end

      # Issues a code for an address, invalidating any earlier one.
      #
      # Leaving earlier codes alive would mean every request widened the window
      # instead of restarting it, so a person who asked three times would have
      # three live codes and an attacker three chances.
      def issue(email:)
        address = normalize_email(email)
        code = generate_code

        record = transaction do
          where(email: address, consumed_at: nil).delete_all

          create!(
            email: address,
            code_digest: digest(code),
            request_id: SecureRandom.hex(32),
            expires_at: Time.current + LIFETIME
          )
        end

        # The code is returned in memory and never written anywhere. This is the
        # only moment it exists in readable form.
        record.instance_variable_set(:@code, code)
        record
      end

      # Redeems a code, returning the address it belongs to, or raises.
      #
      # One error for every refusal. Distinguishing "wrong code" from "expired"
      # from "too many attempts" from "no such request" tells an attacker which
      # wall they hit and therefore whether it is worth continuing.
      def redeem!(request_id:, code:)
        record = find_by(request_id: request_id.to_s, consumed_at: nil)
        raise InvalidCode unless record&.usable?

        if record.attempts >= MAX_ATTEMPTS
          record.destroy!
          raise InvalidCode
        end

        unless secure_compare(digest(code), record.code_digest)
          record.increment!(:attempts)
          # At the cap the row goes, so there is nothing left to guess against
          # and nothing left to leak.
          record.destroy! if record.attempts >= MAX_ATTEMPTS
          raise InvalidCode
        end

        # Conditional, so two submissions of the same correct code in flight at
        # once produce one redemption rather than two.
        claimed = where(id: record.id, consumed_at: nil).update_all(consumed_at: Time.current)
        raise InvalidCode if claimed.zero?

        record.email
      end

      def digest(code, secret: self.secret)
        OpenSSL::HMAC.hexdigest("SHA256", secret, code.to_s)
      end

      def secure_compare(left, right)
        OpenSSL.secure_compare(left.to_s, right.to_s)
      end

      def normalize_email(email)
        email.to_s.strip.downcase
      end

      # A secret of its own, not the application's signing key.
      #
      # Derived through Rails' key generator so it is stable across boots and
      # distinct from every other derived key, which means a leak of one does
      # not compromise the others. An application may set its own.
      def secret
        SparrowAuth.config.otp_secret ||
          Rails.application.key_generator.generate_key("sparrow_auth/one_time_code", 32)
      end
    end

    attr_reader :code

    def usable?
      consumed_at.nil? && expires_at.present? && expires_at > Time.current
    end

    # Codes are live secrets. Nothing here prints the code, and the digest is
    # not printed either: a digest plus a six-digit search space is a
    # confirmation oracle for anyone who can compute the HMAC.
    def inspect
      "#<SparrowAuth::OneTimeCode id=#{id} email=#{email.inspect} " \
        "attempts=#{attempts} usable=#{usable?} code=[never stored] digest=[redacted]>"
    end
    alias_method :to_s, :inspect
  end
end
