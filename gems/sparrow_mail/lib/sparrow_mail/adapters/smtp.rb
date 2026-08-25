# frozen_string_literal: true

require "mail"
require_relative "base"

module SparrowMail
  module Adapters
    # Plain SMTP. The escape hatch that covers every provider without a
    # first-class adapter here, plus self-hosted relays.
    #
    #   config.adapter  = :smtp
    #   config.settings = {
    #     address:   "smtp.example.com",
    #     port:      587,
    #     user_name: ENV["SMTP_USERNAME"],
    #     password:  ENV["SMTP_PASSWORD"]
    #   }
    #
    # Delivery goes through Mail::SMTP, which is already a dependency and is
    # better tested than anything we would write over Net::SMTP directly. What
    # this adapter adds is the SparrowMail contract: SMTP status codes
    # translated into the same error taxonomy every other adapter raises, and
    # nothing logged.
    #
    # SMTP has no sandbox, so sandbox mode is handled by the core: nothing is
    # sent and the message is recorded locally. It has no tag, metadata or
    # stream concept either, and the X-Sparrow-* control headers are stripped
    # before the message goes over the wire.
    class SMTP < Base
      adapter_name :smtp
      display_name "SMTP"
      required_settings :address

      DEFAULT_PORT = 587

      # Which relay, on which port, as whom. Anything else about an SMTP
      # message is invisible to the receiving side's view of the sender.
      def self.identity_settings
        [:address, :port, :user_name]
      end

      # SMTP reply codes, grouped by what an application can usefully do about
      # them. Note that 4xx and 5xx do not map cleanly onto "temporary" and
      # "permanent" here, because this gem never retries either way — the
      # grouping is about which error class tells the truth.
      THROTTLING_CODES = [421, 450, 452, 454].freeze
      RECIPIENT_CODES = [510, 511, 512, 513, 550, 551, 552, 553].freeze
      AUTHENTICATION_CODES = [530, 534, 535, 538].freeze

      # Postfix, Sendmail and Exim all answer a queued message like
      # "250 2.0.0 Ok: queued as 4F1kD62Rz". There is no standard for it, so
      # a message id is best-effort and falls back to the message's own.
      QUEUED_ID = /queued as ([^\s,;]+)/i

      def deliver_envelope(envelope)
        response = Mail::SMTP.new(smtp_settings).deliver!(deliverable(envelope))

        success_result(envelope, message_id: message_id_from(response, envelope))
      rescue Net::SMTPAuthenticationError => e
        raise smtp_error(AuthenticationError, e, envelope)
      rescue Net::SMTPServerBusy, Net::SMTPFatalError, Net::SMTPSyntaxError,
        Net::SMTPUnknownError => e
        raise smtp_error(error_class_for(status_code(e)), e, envelope)
      end

      private

      # The message as it should go over the wire, with the X-Sparrow-* control
      # headers removed. Unlike the API adapters, SMTP hands the whole message
      # to the far end, so without this the gem's private vocabulary would be
      # published to every receiving mail server.
      #
      # Rebuilt from the stripped MIME rather than mutated, so the caller's own
      # Mail::Message is untouched. That loses Bcc, which the mail gem
      # deliberately omits from the encoded form, so the SMTP envelope
      # recipients are restated explicitly from the parsed envelope. Getting
      # this wrong would silently stop delivering to blind copies.
      def deliverable(envelope)
        return envelope.mail if Envelope::CONTROL_HEADERS.none? { |h| envelope.mail.header[h] }

        Mail.new(envelope.to_mime).tap do |message|
          message.smtp_envelope_from = envelope.from.email
          message.smtp_envelope_to = envelope.all_recipients.map(&:email)
        end
      end

      def smtp_settings
        {
          address: settings[:address],
          port: settings.fetch(:port, DEFAULT_PORT),
          domain: settings[:domain],
          user_name: settings[:user_name],
          password: settings[:password],
          authentication: settings[:authentication],
          enable_starttls: settings[:enable_starttls],
          enable_starttls_auto: settings.fetch(:enable_starttls_auto, true),
          openssl_verify_mode: settings[:openssl_verify_mode],
          ssl: settings[:ssl],
          tls: settings[:tls],
          open_timeout: settings.fetch(:open_timeout, Transport::Http::DEFAULT_OPEN_TIMEOUT),
          read_timeout: settings.fetch(:read_timeout, Transport::Http::DEFAULT_READ_TIMEOUT),
          return_response: true
        }.compact
      end

      def message_id_from(response, envelope)
        queued = response.respond_to?(:string) ? response.string.to_s[QUEUED_ID, 1] : nil

        queued || envelope.mail.message_id
      end

      def error_class_for(code)
        case code
        when *AUTHENTICATION_CODES then AuthenticationError
        when *THROTTLING_CODES then RateLimitError
        when *RECIPIENT_CODES then InvalidRecipientError
        else ProviderError
        end
      end

      def status_code(error)
        return nil unless error.respond_to?(:response) && error.response

        error.response.status.to_i
      end

      # An SMTP server's rejection text can quote the message it rejected, so it
      # goes through the redactor exactly like an API's error payload.
      def smtp_error(error_class, error, envelope)
        error_class.new(
          nil,
          adapter: self.class.adapter_name,
          status_code: status_code(error),
          provider_message: Redactor.provider_message(error.message, envelope: envelope),
          recipients: envelope.all_recipients.size
        )
      end
    end
  end
end
