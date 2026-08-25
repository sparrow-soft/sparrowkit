# frozen_string_literal: true

require "securerandom"
require_relative "base"

module SparrowMail
  module Adapters
    # Records messages instead of sending them. This is what replaces Mailtrap
    # and friends in development, test and CI.
    #
    #   config.adapter = :test
    #   SparrowMail.deliveries.last.subject
    #
    # It reports native sandbox support because it has no provider to be
    # sandboxed from. Switching sandbox on changes nothing about what it does,
    # which keeps its behaviour identical in both modes.
    #
    # Failures can be injected, because a test suite that only ever exercises
    # the happy path is how unhandled delivery errors reach production:
    #
    #   SparrowMail::Adapters::Test.fail_with(
    #     SparrowMail::RateLimitError,
    #     status_code: 429,
    #     payload: {"message" => "Too many requests"}
    #   )
    #
    # The injected payload goes through SparrowMail::Redactor exactly as a
    # real provider's response would, so an application's error handling is
    # tested against the same redacted shape it will see in production.
    class Test < Base
      adapter_name :test
      display_name "Test"

      class << self
        attr_reader :failure, :call_count, :last_envelope
        attr_accessor :next_message_id

        def native_sandbox?
          true
        end

        # Records rather than sends, so there is no reputation to keep apart.
        def reputation_bearing?
          false
        end

        # Not a way of sending mail to anybody, so not one to offer.
        def provider?
          false
        end

        def reset!
          @failure = nil
          @call_count = 0
          @last_envelope = nil
          @next_message_id = nil
        end

        # Every subsequent send raises, until #stop_failing.
        def fail_with(error_class, message: nil, status_code: nil, payload: nil,
          provider_message: nil)
          @failure = {
            error_class: error_class,
            message: message,
            status_code: status_code,
            payload: payload || provider_message
          }
        end

        def stop_failing
          @failure = nil
        end

        def record_call(envelope)
          @call_count = call_count.to_i + 1
          @last_envelope = envelope
        end
      end

      reset!

      def deliver_envelope(envelope)
        self.class.record_call(envelope)

        raise build_failure(envelope) if self.class.failure

        # In sandbox mode the core has already recorded this message; recording
        # it again here would double every entry.
        SparrowMail.record_delivery(envelope) unless envelope.sandbox?

        success_result(
          envelope,
          message_id: self.class.next_message_id || "test-#{SecureRandom.hex(8)}"
        )
      end

      private

      def build_failure(envelope)
        failure = self.class.failure

        failure[:error_class].new(
          failure[:message],
          adapter: self.class.adapter_name,
          status_code: failure[:status_code],
          provider_message: Redactor.provider_message(failure[:payload], envelope: envelope),
          recipients: envelope.all_recipients.size
        )
      end
    end
  end
end
