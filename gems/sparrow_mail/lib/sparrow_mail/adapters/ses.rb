# frozen_string_literal: true

require_relative "base"

begin
  require "aws-sdk-sesv2"
rescue LoadError
  raise LoadError, "the sparrow_mail SES adapter needs the aws-sdk-sesv2 gem. " \
    "Add `gem \"aws-sdk-sesv2\"` to your Gemfile."
end

module SparrowMail
  module Adapters
    # Amazon SES, via the v2 API.
    #
    #   config.adapter  = :ses
    #   config.settings = {region: "us-east-1"}
    #
    # Credentials come from the AWS SDK's normal chain (environment, instance
    # profile, shared config) unless `access_key_id` and `secret_access_key` are
    # given explicitly.
    #
    # This adapter posts the message as raw MIME rather than rebuilding it as a
    # structured payload. SES accepts that, and it means attachments, encoding
    # and threading headers survive exactly as the mail gem produced them
    # instead of being re-serialised by us.
    #
    # Two things are worth knowing:
    #
    #   * `retry_limit: 0`. The AWS SDK retries by default, which would break
    #     the never-retry rule from inside a dependency. This is the one place
    #     in the gem where a third party would otherwise retry on our behalf.
    #   * SES has no per-request sandbox — its sandbox is an account-level
    #     state — so sandbox mode is handled by the core: nothing is sent and
    #     the message is recorded locally.
    #
    # Mapping notes: SES message tags are name/value pairs, which fits metadata
    # exactly and tags not at all, so metadata becomes `email_tags` (the things
    # that appear as CloudWatch dimensions) and tags are not sent. The
    # X-Sparrow-* control headers are stripped from the raw MIME before it is
    # posted, so this gem's private vocabulary is not published to the
    # receiving mail server.
    class SES < Base
      adapter_name :ses
      display_name "Amazon SES"
      required_settings :region

      # SES exception names that mean something more specific than their HTTP
      # status does. Nearly everything SES rejects comes back as a 400, so the
      # exception name is what carries the diagnosis.
      RECIPIENT_ERRORS = %w[
        MessageRejected
        MailFromDomainNotVerifiedException
      ].freeze

      RATE_LIMIT_ERRORS = %w[
        TooManyRequestsException
        LimitExceededException
        SendingQuotaExceededException
      ].freeze

      # The account cannot send at all. Not a recipient problem and not a
      # credential problem: from the caller's side, this provider is down.
      ACCOUNT_ERRORS = %w[
        AccountSuspendedException
        SendingPausedException
      ].freeze

      AUTHENTICATION_ERRORS = %w[
        AccessDeniedException
        UnrecognizedClientException
        InvalidClientTokenId
        MissingAuthenticationTokenException
      ].freeze

      # SES separates reputation by configuration set, which is also how it
      # separates dedicated IP pools. Without one per stream it cannot tell
      # bulk from transactional, whatever the message says.
      def self.identity_settings
        [:region, :access_key_id, :configuration_set_name]
      end

      def deliver_envelope(envelope)
        response = client.send_email(request(envelope))

        success_result(envelope, message_id: response.message_id)
      rescue Seahorse::Client::NetworkingError => e
        raise NetworkError.new(
          nil,
          adapter: self.class.adapter_name,
          provider_message: Redactor.provider_message(e.class.name, envelope: envelope),
          recipients: envelope.all_recipients.size
        )
      rescue Aws::Errors::MissingCredentialsError, Aws::Errors::MissingRegionError => e
        raise ConfigurationError, "the ses adapter is not configured: #{e.class}"
      rescue Aws::Errors::ServiceError => e
        raise service_error(e, envelope)
      end

      private

      def client
        @client ||= Aws::SESV2::Client.new(client_options)
      end

      def client_options
        options = {
          region: settings[:region],
          # The AWS SDK retries by default. A send is never retried.
          retry_limit: 0
        }

        if settings[:access_key_id] && settings[:secret_access_key]
          options[:credentials] = Aws::Credentials.new(
            settings[:access_key_id],
            settings[:secret_access_key],
            settings[:session_token]
          )
        end

        options[:endpoint] = settings[:endpoint] if settings[:endpoint]
        options
      end

      def request(envelope)
        request = {
          from_email_address: envelope.from.to_s,
          destination: destination(envelope),
          content: {raw: {data: envelope.to_mime}}
        }

        tags = email_tags(envelope)
        request[:email_tags] = tags if tags.any?

        if settings[:configuration_set_name]
          request[:configuration_set_name] = settings[:configuration_set_name]
        end

        request
      end

      def destination(envelope)
        destination = {to_addresses: envelope.to.map(&:email)}
        destination[:cc_addresses] = envelope.cc.map(&:email) if envelope.cc.any?
        destination[:bcc_addresses] = envelope.bcc.map(&:email) if envelope.bcc.any?
        destination
      end

      # SES restricts tag names and values to letters, digits, underscores and
      # hyphens. Anything else is rejected for the whole message, so values are
      # sanitised rather than allowed to fail the send.
      def email_tags(envelope)
        envelope.metadata.map do |name, value|
          {name: sanitize_tag(name), value: sanitize_tag(value)}
        end
      end

      def sanitize_tag(value)
        sanitized = value.to_s.gsub(/[^A-Za-z0-9_-]/, "_")
        sanitized.empty? ? "_" : sanitized[0, 256]
      end

      def service_error(error, envelope)
        error_class_for(error).new(
          nil,
          adapter: self.class.adapter_name,
          status_code: http_status(error),
          provider_code: error.code,
          provider_message: Redactor.provider_message(error.message, envelope: envelope),
          recipients: envelope.all_recipients.size
        )
      end

      def error_class_for(error)
        case error.code.to_s
        when *RECIPIENT_ERRORS then InvalidRecipientError
        when *RATE_LIMIT_ERRORS then RateLimitError
        when *AUTHENTICATION_ERRORS then AuthenticationError
        when *ACCOUNT_ERRORS then ProviderError
        else self.class.error_for_status(http_status(error))
        end
      end

      def http_status(error)
        error.context&.http_response&.status_code
      end
    end
  end
end
