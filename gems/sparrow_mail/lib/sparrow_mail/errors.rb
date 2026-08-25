# frozen_string_literal: true

require_relative "redactor"

module SparrowMail
  # Base class for everything this gem raises. An application that wants to
  # catch "any mail problem" catches this.
  class Error < StandardError; end

  # The adapter, its settings, or the message itself is wrong in a way that
  # retrying identically could never fix: a missing API key, a message with no
  # recipient, an unregistered adapter name.
  #
  # Deliberately NOT a DeliveryError. This is a caller bug, not a failed send,
  # and it is raised before any provider is contacted. It is also the one error
  # `SparrowMail.deliver` still raises rather than returning, because a
  # misconfigured application should fall over at boot rather than quietly
  # return failures for every message.
  class ConfigurationError < Error; end

  # Base class for a send that reached an adapter and failed.
  #
  # Every failure lands in exactly one of five categories. The categories are
  # the gem's vocabulary, not any provider's, which is what lets an application
  # write one `rescue SparrowMail::RateLimitError` and have it keep meaning the
  # same thing after switching providers.
  #
  # Deliberately absent: any `retryable?` predicate, and any trace of the
  # message body. The gem never retries, and a retry hint here would be an
  # invitation to reintroduce retries at the call site.
  #
  # `provider_message` is redacted HERE as well as by every caller, and the
  # difference matters. This comment used to say it "has been through
  # SparrowMail::Redactor before it arrives" -- a claim about what callers do,
  # made in the one place that could enforce it and did not. Every adapter did
  # remember; the guarantee was still only as good as the next one.
  #
  # What the constructor can do without an envelope is the credential shapes and
  # the length cap. Removing OUR OWN message content still needs the envelope,
  # so adapters go on passing it, and that half remains a convention rather than
  # a rule. Saying which half is which beats claiming both.
  class DeliveryError < Error
    CATEGORIES = %i[auth invalid_recipient rate_limited provider_down unknown].freeze

    class << self
      def category(value = nil)
        if value
          unless CATEGORIES.include?(value)
            raise ArgumentError, "unknown category #{value.inspect}, expected one of #{CATEGORIES}"
          end

          @category = value
        end

        (defined?(@category) && @category) ? @category : superclass.category
      end
    end

    @category = :unknown

    attr_reader :adapter, :status_code, :provider_code, :provider_message, :recipients

    def initialize(message = nil, adapter: nil, status_code: nil, provider_code: nil,
      provider_message: nil, recipients: nil)
      @adapter = adapter
      @status_code = status_code
      @provider_code = provider_code
      @provider_message = Redactor.provider_message(provider_message)
      @recipients = recipients

      super(message || default_message)
    end

    def category
      self.class.category
    end

    # Log-safe. Every value here is either ours or has been through the
    # redactor; none of it is message content.
    def to_h
      {
        error: self.class.name,
        category: category,
        adapter: adapter,
        status_code: status_code,
        provider_code: provider_code,
        provider_message: provider_message,
        recipients: recipients
      }.compact
    end

    private

    def default_message
      parts = ["#{adapter || "sparrow_mail"} delivery failed"]
      parts << "status=#{status_code}" if status_code
      parts << "code=#{provider_code}" if provider_code
      parts << provider_message if provider_message && !provider_message.empty?
      parts.join(" ")
    end
  end

  # The provider rejected our credentials. A send with the same key fails the
  # same way; this needs a human.
  class AuthenticationError < DeliveryError
    category :auth
  end

  # The provider rejected one or more addresses: malformed, suppressed,
  # unsubscribed, or on a bounce list. Sending again changes nothing.
  class InvalidRecipientError < DeliveryError
    category :invalid_recipient
  end

  # The provider throttled us. The application decides whether and when to send
  # a fresh message; the gem does not decide for it.
  class RateLimitError < DeliveryError
    category :rate_limited
  end

  # The provider failed in a way it describes as its own fault. Typically a 5xx.
  class ProviderError < DeliveryError
    category :provider_down
  end

  # We never got a usable answer: connection refused, TLS failure, timeout.
  # Categorised with provider-down because from here they are the same thing.
  #
  # A timeout is genuinely ambiguous — the message may well have been sent —
  # and that ambiguity is precisely why this gem does not retry.
  class NetworkError < DeliveryError
    category :provider_down
  end

  # Something failed that we could not classify: an adapter raised an exception
  # nobody anticipated, or a provider answered in a shape we do not recognise.
  # Kept distinct from ProviderError on purpose, so "we do not know what
  # happened" never masquerades as "the provider is down".
  class UnknownError < DeliveryError
    category :unknown
  end
end
