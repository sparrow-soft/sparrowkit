# frozen_string_literal: true

require "net/http"
require_relative "../transport/http"

module SparrowMail
  module Adapters
    # The adapter interface, and the single place where the two inviolable rules
    # are enforced.
    #
    # Adapters implement one method, +deliver_envelope+, and never override
    # +deliver!+. That split is the whole design. It means:
    #
    #   * **Bodies are never logged**, because adapters do no logging at all.
    #     Every log line this gem emits comes from #log_delivery below, built
    #     from Envelope#log_summary and Result#to_h — two objects that have no
    #     way to hold body content. A new adapter cannot leak a body by
    #     forgetting a convention, because it is never handed a logger.
    #
    #   * **A send is never retried**, because +deliver_envelope+ is called from
    #     exactly one place, exactly once, with no rescue that re-invokes it.
    #     A new adapter cannot introduce a retry loop without it showing up as
    #     an extra request in the conformance suite's call count.
    #
    # On the second rule: the tempting case is a timeout, where the send may
    # well have succeeded and we simply never heard. Sending again would deliver
    # a second copy of a one-time code. The gem surfaces the ambiguity as a
    # NetworkError and lets the application decide, in full knowledge that it is
    # making a *new* send rather than completing an old one.
    #
    # A minimal adapter:
    #
    #   class MyAdapter < SparrowMail::Adapters::Base
    #     adapter_name :my_provider
    #     required_settings :api_key
    #
    #     def deliver_envelope(envelope)
    #       response = http.post("/send", payload_for(envelope))
    #       raise_for_response(response, envelope) unless response.success?
    #       SparrowMail::Result.new(
    #         adapter: self.class.adapter_name,
    #         message_id: response.json["id"],
    #         recipients: envelope.all_recipients.size
    #       )
    #     end
    #   end
    #
    # See the gem README, "Writing an adapter", and run it against the
    # conformance suite before shipping it.
    class Base
      # Exceptions that mean we never got a usable answer from the provider.
      # A timeout belongs here and is genuinely ambiguous — see above.
      NETWORK_EXCEPTIONS = [
        SocketError,
        SystemCallError,
        IOError,
        Net::OpenTimeout,
        Net::ReadTimeout,
        Timeout::Error,
        OpenSSL::SSL::SSLError
      ].freeze

      class << self
        def adapter_name(name = nil)
          @adapter_name = name.to_sym if name
          @adapter_name || default_adapter_name
        end

        # How the provider spells its own name, for anything a person reads.
        #
        #     display_name "SendLayer"
        #
        # `adapter_name` is the key an application configures with and stays
        # lowercase; this is the brand. They are different things and only one
        # of them is Amazon's to capitalise.
        #
        # It lives on the adapter because the adapter is what knows. The
        # console derives everything it shows from these classes and carries no
        # list of providers of its own -- a table of names there would drift
        # from the gem it configures, silently, and an adapter registered by an
        # application would not be in it at all.
        def display_name(name = nil)
          @display_name = name.to_s if name
          @display_name || default_display_name
        end

        # Settings that must be present and non-blank before the adapter will
        # build. Checked at construction so a misconfigured deployment fails at
        # boot rather than on the first sign-in email.
        def required_settings(*names)
          @required_settings = names.map(&:to_sym) unless names.empty?
          @required_settings || []
        end

        # True when the provider has a sandbox of its own that we can switch on
        # per request. Adapters that say true still make the request in sandbox
        # mode, which exercises the full path; adapters that say false are
        # short-circuited by the core and never contact the provider.
        def native_sandbox?
          false
        end

        # The settings a provider uses to tell one sender from another, and so
        # to decide whose reputation a message affects. Two streams whose
        # identities match share a reputation however differently they are
        # labelled, which is why the core refuses to build them.
        #
        # Adapters override this when their provider's identity is more than an
        # API key: Mailgun's is the key and the sending domain, SMTP's is the
        # relay and the login.
        def identity_settings
          [:api_key]
        end

        # False for adapters that do not really send, so nothing is put at risk
        # by two streams looking alike.
        def reputation_bearing?
          true
        end

        # Whether this adapter is something a developer would choose on the
        # settings page as the way their mail reaches people.
        #
        # False for the two that hand mail to nobody: :test records in memory
        # and :preview writes to a folder. Both are perfectly good adapters and
        # both are deliberately selectable in code; neither belongs in a list
        # headed "how does your mail get sent", and offering them there made the
        # panel's "send a test email" button able to report success having
        # reached no network at all.
        #
        # Asked of the class rather than kept as a list of names in the console,
        # so an adapter added tomorrow answers for itself.
        def provider?
          true
        end

        def error_for_status(status)
          case status.to_i
          when 401, 403 then AuthenticationError
          when 400, 422 then InvalidRecipientError
          when 429 then RateLimitError
          else ProviderError
          end
        end

        private

        def default_adapter_name
          name.to_s.split("::").last
            .gsub(/([a-z\d])([A-Z])/, '\1_\2')
            .downcase.to_sym
        end

        # A readable fallback for an adapter that never said. Title-cases the
        # key: :my_provider -> "My Provider". Wrong for a brand that is not
        # spelled that way, which is exactly why `display_name` exists.
        def default_display_name
          adapter_name.to_s.split("_").map(&:capitalize).join(" ")
        end
      end

      attr_reader :settings

      def initialize(settings = {})
        @settings = normalize_settings(settings)
        validate_settings!
      end

      # Delivers a Mail::Message or an Envelope. Not overridden by adapters.
      #
      # Envelope construction sits outside the rescue on purpose: a message with
      # no recipient is a caller bug, and it should surface as the
      # ConfigurationError it is rather than be dressed up as a delivery
      # failure. It also means a malformed message never reaches the provider.
      def deliver!(message)
        envelope = build_envelope(message)
        started_at = monotonic_now

        begin
          SparrowMail.record_delivery(envelope) if envelope.sandbox?

          result = perform_delivery(envelope)
          result = result.with(
            sandbox: envelope.sandbox?,
            stream: envelope.stream,
            duration_ms: elapsed_ms(started_at)
          )

          log_delivery(envelope, result)
          result
        rescue SparrowMail::Error => e
          log_failure(envelope, e, elapsed_ms(started_at))
          raise
        rescue *NETWORK_EXCEPTIONS => e
          raise wrapped_failure(NetworkError, e, envelope, started_at)
        rescue => e
          # Unknown rather than ProviderError: an exception nobody anticipated
          # is not evidence that the provider is down, and saying so would be a
          # guess dressed up as a diagnosis.
          raise wrapped_failure(UnknownError, e, envelope, started_at)
        end
      end

      # The same send, returning a Result that carries the failure instead of
      # raising it. For callers that treat a failed send as a value: a mailer
      # job recording an outcome, a bulk send that must not abort on one bad
      # address.
      #
      #   result = adapter.deliver(mail)
      #   result.category  # => :rate_limited
      #
      # ConfigurationError still raises. A message with no recipient or an
      # adapter with no API key is a caller bug, and returning it as a value
      # would let a misconfigured deployment quietly report failures forever.
      def deliver(message)
        deliver!(message)
      rescue DeliveryError => e
        Result.failed(e, stream: Envelope.stream_from(message))
      end

      def sandbox?
        truthy?(settings[:sandbox])
      end

      # What the provider will see as the sender for mail on this stream.
      # Adapters whose provider models streams natively include the resolved
      # provider-side stream here, because for them the stream is part of the
      # identity rather than something layered on top of it.
      def sending_identity(_stream)
        self.class.identity_settings.map { |key| settings[key] }
      end

      # Adapters implement this and nothing else.
      def deliver_envelope(_envelope)
        raise NotImplementedError,
          "#{self.class} must implement #deliver_envelope(envelope) and return a SparrowMail::Result"
      end

      def inspect
        "#<#{self.class.name} adapter=#{self.class.adapter_name} sandbox=#{sandbox?}>"
      end
      alias_method :to_s, :inspect

      private

      # The one and only call to deliver_envelope. Guard it jealously.
      def perform_delivery(envelope)
        if envelope.sandbox? && !self.class.native_sandbox?
          return Result.new(
            adapter: self.class.adapter_name,
            recipients: envelope.all_recipients.size,
            sandbox: true,
            delivered: false
          )
        end

        deliver_envelope(envelope)
      end

      def build_envelope(message)
        return message if message.is_a?(Envelope)

        apply_default_from(message)
        Envelope.from_mail(message, sandbox: sandbox?)
      end

      # Only when the message has none of its own. A mailer that names a sender
      # always wins.
      def apply_default_from(mail)
        return if settings[:default_from].nil?
        return if mail[:from] && !mail[:from].addrs.empty?

        mail.from = settings[:default_from]
      rescue NoMethodError
        mail.from = settings[:default_from]
      end

      def wrapped_failure(error_class, error, envelope, started_at)
        failure = error_class.new(
          nil,
          adapter: self.class.adapter_name,
          provider_message: Redactor.provider_message(exception_summary(error), envelope: envelope),
          recipients: envelope.all_recipients.size
        )
        log_failure(envelope, failure, elapsed_ms(started_at))
        failure
      end

      # Raises the right error class for an HTTP response, with the provider's
      # diagnostics passed through the redactor first.
      def raise_for_response(status:, payload:, envelope:, provider_code: nil)
        raise self.class.error_for_status(status).new(
          nil,
          adapter: self.class.adapter_name,
          status_code: status,
          provider_code: provider_code,
          provider_message: Redactor.provider_message(payload, envelope: envelope),
          recipients: envelope.all_recipients.size
        )
      end

      # An HTTP client carrying this adapter's timeouts. Adapters use this
      # rather than building a Transport::Http themselves, so that the
      # never-retry configuration is applied in one place.
      def http_client(base_url:, headers: {})
        Transport::Http.new(
          base_url: base_url,
          headers: headers,
          open_timeout: settings.fetch(:open_timeout, Transport::Http::DEFAULT_OPEN_TIMEOUT),
          read_timeout: settings.fetch(:read_timeout, Transport::Http::DEFAULT_READ_TIMEOUT)
        )
      end

      def success_result(envelope, message_id: nil)
        Result.new(
          adapter: self.class.adapter_name,
          message_id: message_id,
          recipients: envelope.all_recipients.size
        )
      end

      def normalize_settings(settings)
        (settings || {}).to_h.each_with_object({}) do |(key, value), result|
          result[key.to_sym] = value
        end
      end

      def validate_settings!
        missing = self.class.required_settings.reject { |key| present?(settings[key]) }
        return if missing.empty?

        raise ConfigurationError,
          "#{self.class.adapter_name} adapter is missing required setting(s): #{missing.join(", ")}"
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end

      def truthy?(value)
        return false if value.nil?
        return value if [true, false].include?(value)

        %w[1 true yes on].include?(value.to_s.strip.downcase)
      end

      # An exception's own message may contain anything the provider or a
      # third-party library put there, including our body. Name the class, keep
      # the text only after the redactor has seen it.
      def exception_summary(error)
        "#{error.class}: #{error.message}"
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def elapsed_ms(started_at)
        return nil if started_at.nil?

        ((monotonic_now - started_at) * 1000).round
      end

      # --- the only logging in this gem -------------------------------------
      #
      # Both methods build their line from hashes that cannot contain body
      # content: Envelope#log_summary is a fixed set of counts and flags, and
      # DeliveryError#to_h has already been through the redactor. Nothing here
      # touches envelope.text_body, envelope.subject, or the Mail object.
      # spec/sparrow_mail/inviolable_rules_spec.rb fails the build if a
      # logger call appears anywhere else in lib/.

      def log_delivery(envelope, result)
        write_log(:info, {event: "delivery"}.merge(result.to_h).merge(envelope.log_summary))
      end

      def log_failure(envelope, error, duration_ms)
        details = error.respond_to?(:to_h) ? error.to_h : {error: error.class.name}

        write_log(:warn, {
          event: "delivery_failed",
          duration_ms: duration_ms
        }.merge(details).merge(envelope.log_summary))
      end

      def write_log(level, fields)
        logger = SparrowMail.configuration.logger
        return if logger.nil?

        logger.public_send(
          level,
          "[sparrow_mail] " + fields.compact.map { |key, value| "#{key}=#{value}" }.join(" ")
        )
      end
    end
  end
end
