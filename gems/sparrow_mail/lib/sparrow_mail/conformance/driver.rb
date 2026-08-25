# frozen_string_literal: true

module SparrowMail
  module Conformance
    # What the conformance suite needs from an adapter in order to hold it to
    # the same contract as every other adapter.
    #
    # The suite cannot stub a provider it has never heard of, so each adapter
    # brings a driver that knows how to make its own provider succeed, fail in
    # each of the five ways that matter, and echo submitted content back. The
    # driver is the only place provider-specific knowledge lives; the contract
    # itself is identical for all of them.
    #
    # Implement one of these for a new adapter, point the shared examples at it,
    # and the adapter is held to the same standard as the ones that ship here.
    class Driver
      # Settings for an adapter that would work against the stubbed provider.
      def settings
        raise NotImplementedError, "#{self.class} must implement #settings"
      end

      # Arrange for the next send to be accepted, reporting this message id.
      def stub_success(message_id: "conformance-message-id")
        raise NotImplementedError, "#{self.class} must implement #stub_success"
      end

      # Arrange for the next send to fail in one of these ways:
      #
      #   :authentication   credentials rejected
      #   :invalid_recipient  the address was refused
      #   :rate_limit       throttled
      #   :server_error     the provider broke
      #   :network_failure  no usable answer at all
      def stub_failure(kind)
        raise NotImplementedError, "#{self.class} must implement #stub_failure"
      end

      # Arrange for the next send to fail with the provider echoing `text` back
      # in its error response. Real providers do this constantly: a validation
      # error quotes the field it rejected, and that field is often the body.
      #
      # Put `text` in BOTH a diagnostic key the redactor allows through AND a
      # submitted-content key it does not, so the suite exercises both defences.
      def stub_echo(text)
        raise NotImplementedError, "#{self.class} must implement #stub_echo"
      end

      # How many requests actually reached the provider. This is what proves
      # the never-retry rule rather than asserting it.
      def request_count
        raise NotImplementedError, "#{self.class} must implement #request_count"
      end

      # Custom headers as the provider received them, or nil if the provider
      # has no way to carry them.
      def sent_headers
        nil
      end

      # The following four report what the provider actually received, so the
      # suite can check that the envelope survived the trip rather than only
      # that the request was accepted. An adapter that dropped the subject would
      # otherwise pass every other test here.
      #
      # Return nil from any of them only if the provider genuinely has no
      # equivalent; the suite skips rather than fails in that case.

      # The sender address, without the display name.
      def sent_from
        nil
      end

      # Every To recipient's address, in order.
      def sent_to
        nil
      end

      def sent_subject
        nil
      end

      # Every Reply-To address.
      def sent_reply_to
        nil
      end

      # Tags as the provider received them, or nil if the provider has no tag
      # concept.
      def sent_tags
        nil
      end

      # The provider's own stream identifier for the last message, or nil if the
      # provider has no stream concept. Only Postmark and Amazon SES do; for
      # everything else the separation comes from per-stream configuration
      # (different credentials, sending domain or relay) rather than from a
      # field in the payload.
      def sent_stream
        nil
      end

      # Metadata as the provider received them, or nil if the provider has no
      # metadata concept.
      def sent_metadata
        nil
      end

      # Did the last request carry the provider's own sandbox marker? Only
      # consulted for adapters whose class reports native_sandbox? — everything
      # else is short-circuited by the core and never sends at all.
      def sandbox_marked?
        false
      end

      # True only for adapters whose purpose is to record rather than send —
      # the test adapter, and anything like it. Every production adapter leaves
      # SparrowMail.deliveries alone outside sandbox mode, and the suite
      # checks that.
      def records_outside_sandbox?
        false
      end

      # Anything the driver needs to tear down between examples.
      def reset!
      end
    end
  end
end
