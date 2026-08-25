# frozen_string_literal: true

module SparrowMail
  # Turns a provider's error payload into something safe to put in an exception
  # message and a log line.
  #
  # Two passes, in this order, because either alone is insufficient:
  #
  #   1. **Allowlist.** Only keys known to carry diagnostics survive. Providers
  #      routinely echo the submitted message back in a validation error —
  #      Postmark returns HtmlBody, SendGrid quotes the offending field's value
  #      — and an allowlist is the only defence that holds against a provider
  #      inventing a new key next quarter.
  #   2. **Scrub.** Some providers echo submitted content *into* an allowlisted
  #      key ("could not parse body: <the whole body>"). The second pass removes
  #      anything matching the outgoing message's own content.
  #
  # Then a length cap, because an unbounded provider string is body-shaped by
  # definition.
  module Redactor
    MAX_LENGTH = 500

    # Keys across SendLayer, Postmark, SendGrid, Mailgun, SES and generic JSON
    # APIs that carry diagnostics rather than submitted content. Compared
    # case-insensitively.
    DIAGNOSTIC_KEYS = %w[
      message error detail details description reason title
      code errorcode error_code type field help status
    ].freeze

    # Keys whose values are containers of diagnostics rather than diagnostics
    # themselves.
    CONTAINER_KEYS = %w[errors error_details messages].freeze

    # Shorter than this and a fragment of the body is too generic to use as a
    # scrub pattern: scrubbing "Hi" would redact half of every provider
    # message. Above it we over-redact happily — a provider diagnostic that
    # loses a long word is a much smaller problem than a sign-in code reaching
    # a log aggregator.
    MIN_SCRUB_LENGTH = 8

    # ...except for runs of digits, which get their own much lower floor.
    #
    # THE ONE SECRET THIS LIBRARY EXISTS TO PROTECT WAS THE ONE IT COULD NOT.
    # sparrow_auth's sign-in code is six digits, MIN_SCRUB_LENGTH is eight, so
    # every code echoed back by a provider was returned verbatim — and the
    # conformance fixture is 29 characters, which is why no test ever said so.
    #
    # Lowering the general floor to four would have fixed it by making "code",
    # "your" and "sent" into scrub patterns, which turns every provider
    # diagnostic into [redacted] soup. A run of digits is different: it is never
    # an English word, so scrubbing it costs a diagnostic nothing and hides
    # exactly the class of secret that is short on purpose.
    MIN_DIGIT_RUN = 4
    DIGIT_RUN = /\d{#{MIN_DIGIT_RUN},}/

    # Shapes that are a credential wherever they appear, matched in the
    # PROVIDER's text rather than derived from ours.
    #
    # The scrub patterns above can only remove what we sent. A provider that
    # echoes back the API key it was called with is quoting something we never
    # put in the message, so nothing derived from the envelope can catch it.
    #
    # Deliberately four narrow shapes and no general "long random-looking run".
    # A 32-character hex string in a diagnostic is at least as likely to be the
    # message id somebody needs in order to chase the delivery.
    CREDENTIAL_SHAPES = [
      /\b[sprk]k_(?:live|test)_[A-Za-z0-9]{8,}/,          # Stripe and friends
      /\bkey-[A-Za-z0-9]{16,}/,                            # Mailgun
      /\bSG\.[A-Za-z0-9_-]{16,}\.[A-Za-z0-9_-]{16,}/,       # SendGrid
      /\bBearer\s+[A-Za-z0-9._~+\/-]{16,}=*/i             # any bearer token
    ].freeze

    REDACTION = "[redacted]"

    class << self
      def provider_message(payload, envelope: nil, limit: MAX_LENGTH)
        text = extract(payload)
        return nil if text.nil?

        text = scrub(text, envelope)
        text = text.to_s.strip
        return nil if text.empty?

        truncate(text, limit)
      end

      # Removes the outgoing message's own content from a string. Matches the
      # body whole, by line, and by individual token, because providers and
      # exception messages echo back all three shapes — a validation error
      # quotes the whole body, a parser error quotes the offending line, and a
      # library exception says "failed on <the token it choked on>", which in
      # transactional mail is very often the code itself.
      def scrub(text, envelope)
        return nil if text.nil?

        # Credential shapes apply with no envelope at all: they are about what
        # the provider said, not about what we sent.
        result = CREDENTIAL_SHAPES.reduce(text.to_s) { |acc, shape| acc.gsub(shape, REDACTION) }
        return result if envelope.nil?

        scrub_patterns(envelope).reduce(result) do |acc, pattern|
          acc.gsub(pattern, REDACTION)
        end
      end

      private

      def extract(payload)
        case payload
        when nil then nil
        when String then presence(payload)
        when Symbol, Numeric then payload.to_s
        when Array then presence(payload.filter_map { |item| extract(item) }.join("; "))
        when Hash then extract_hash(payload)
        else presence(payload.to_s)
        end
      end

      def extract_hash(payload)
        parts = payload.filter_map do |key, value|
          name = key.to_s.downcase

          if CONTAINER_KEYS.include?(name)
            extract(value)
          elsif DIAGNOSTIC_KEYS.include?(name)
            # A diagnostic key holding a container still needs unwrapping;
            # holding anything else is taken at face value.
            value.is_a?(Enumerable) ? extract(value) : presence(value.to_s)
          end
        end

        presence(parts.uniq.join(" "))
      end

      # Everything of ours a provider could quote back.
      #
      # The bodies and attachments were the whole list, and the other three are
      # not decoration: a subject is where several applications put the code
      # before anybody stopped them, metadata is arbitrary application data
      # echoed by every provider that supports it, and a custom header is a
      # place an application can put whatever it likes. All three come back
      # inside provider validation errors.
      def scrub_sources(envelope)
        [
          envelope.text_body,
          envelope.html_body,
          envelope.subject,
          *envelope.attachments.map(&:content),
          *envelope.metadata.to_h.values,
          *envelope.headers.to_h.values
        ].compact
      end

      def scrub_patterns(envelope)
        content = scrub_sources(envelope)

        # Whole values, then lines, then tokens. Sorted longest first so a
        # fragment never pre-empts the fuller match that contains it.
        lines = content.flat_map { |value| value.to_s.split(/\r?\n/) }
        tokens = lines.flat_map { |line| line.split(/\s+/) }

        long = (content + lines + tokens)
          .map { |value| value.to_s.strip }
          .select { |value| value.length >= MIN_SCRUB_LENGTH }

        # And every run of digits in any of it, however short -- see
        # MIN_DIGIT_RUN. Taken from the raw content rather than from `tokens`,
        # so a code that arrives punctuated ("code: 483927.") is still found.
        digits = content.flat_map { |value| value.to_s.scan(DIGIT_RUN) }

        (long + digits)
          .uniq
          .sort_by { |value| -value.length }
          .map { |value| Regexp.new(Regexp.escape(value)) }
      end

      def truncate(text, limit)
        return text if text.length <= limit

        "#{text[0, limit]}..."
      end

      def presence(value)
        return nil if value.nil?

        stripped = value.to_s.strip
        stripped.empty? ? nil : stripped
      end
    end
  end
end
