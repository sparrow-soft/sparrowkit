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
    #   config.settings = {
    #     region: "us-east-1",
    #     access_key_id: ENV["AWS_ACCESS_KEY_ID"],          # optional
    #     secret_access_key: ENV["AWS_SECRET_ACCESS_KEY"]   # optional
    #   }
    #
    # `region` is required and must be one where SES is offered; the control
    # panel offers the list, taken from the AWS SDK's own region data. The two
    # credentials are optional to the adapter: left out, the AWS SDK looks
    # for them itself -- the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
    # environment variables, a shared profile in ~/.aws, or an instance role
    # -- which is the right answer in production. On a laptop with none of
    # those, the panel is where they go, and a send with neither says so.
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
      optional_settings :access_key_id, :secret_access_key

      # The partition data's own name for the service this adapter calls.
      # `Aws::Partitions::Region#services` lists what each region offers, and
      # this is the key it lists SES v2 under.
      PARTITION_SERVICE = "SESV2"

      # The regions where SES v2 is offered, as `[value, label]` pairs for a
      # dropdown: `["us-east-1", "us-east-1 · US East (N. Virginia)"]`.
      #
      # Read from the aws-partitions gem, which the SDK carries and keeps
      # current, rather than typed out here. A list in this file would be
      # right on the day it was written and wrong the next time Amazon opened
      # a region, and nothing would say so. GovCloud and the sovereign cloud
      # are in the list because SES is in them; an application that sends
      # from one is not an edge case to be second-guessed here.
      def self.setting_choices(name)
        return nil unless name.to_sym == :region

        @region_choices ||= Aws.partitions.flat_map do |partition|
          partition.regions.select { |region| region.services.include?(PARTITION_SERVICE) }
        end.map { |region| [region.name, "#{region.name} · #{region.description}"] }
      end

      def self.setting_hint(name)
        case name.to_sym
        when :region
          "The region your sending domain or address is verified in. " \
            "Sending from any other region is refused by SES."
        when :access_key_id, :secret_access_key
          "From an IAM user allowed to send through SES. Leave both blank only if " \
            "the AWS SDK can already find credentials on its own: the AWS_ACCESS_KEY_ID " \
            "and AWS_SECRET_ACCESS_KEY environment variables, a profile in ~/.aws, or " \
            "an instance role."
        end
      end

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
      rescue Aws::Errors::MissingCredentialsError
        # The panel's two credential boxes were left blank and the SDK found
        # nothing either. Naming both places is the whole point: the exception
        # class alone told a developer nothing about where to put a key.
        raise ConfigurationError,
          "the ses adapter has no AWS credentials. Enter an access key ID and " \
          "secret access key in the control panel, or set AWS_ACCESS_KEY_ID and " \
          "AWS_SECRET_ACCESS_KEY where the AWS SDK will find them."
      rescue Aws::Errors::MissingRegionError => e
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
