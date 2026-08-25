# frozen_string_literal: true

module Drivers
  # Drives the test adapter. It has no provider, so "a request" is a call into
  # deliver_envelope and failures are injected directly. It runs the same
  # conformance suite as everything else deliberately: an adapter used by every
  # test suite in the portfolio is the last one that should be allowed to behave
  # differently from production.
  class TestDriver < SparrowMail::Conformance::Driver
    FAILURES = {
      authentication: [SparrowMail::AuthenticationError, 401, "Invalid API key"],
      invalid_recipient: [SparrowMail::InvalidRecipientError, 422, "Recipient rejected"],
      rate_limit: [SparrowMail::RateLimitError, 429, "Too many requests"],
      server_error: [SparrowMail::ProviderError, 500, "Internal server error"],
      network_failure: [SparrowMail::NetworkError, nil, "Connection reset"]
    }.freeze

    def settings
      {}
    end

    # Unlike every other adapter, recording is what this one is for.
    def records_outside_sandbox?
      true
    end

    def stub_success(message_id: "conformance-message-id")
      SparrowMail::Adapters::Test.stop_failing
      SparrowMail::Adapters::Test.next_message_id = message_id
    end

    def stub_failure(kind)
      error_class, status, message = FAILURES.fetch(kind)

      SparrowMail::Adapters::Test.fail_with(
        error_class,
        status_code: status,
        payload: {"message" => message}
      )
    end

    # The echoed text goes in both a key the redactor allows through and one it
    # does not, matching what the HTTP drivers send.
    def stub_echo(text)
      SparrowMail::Adapters::Test.fail_with(
        SparrowMail::InvalidRecipientError,
        status_code: 422,
        payload: {
          "message" => "Message content rejected: #{text}",
          "submitted_body" => text
        }
      )
    end

    def request_count
      SparrowMail::Adapters::Test.call_count
    end

    def sent_headers
      SparrowMail::Adapters::Test.last_envelope&.headers
    end

    def sent_tags
      SparrowMail::Adapters::Test.last_envelope&.tags
    end

    def sent_metadata
      SparrowMail::Adapters::Test.last_envelope&.metadata
    end

    def sandbox_marked?
      SparrowMail::Adapters::Test.last_envelope&.sandbox? || false
    end

    def reset!
      SparrowMail::Adapters::Test.reset!
    end

    def sent_from
      SparrowMail::Adapters::Test.last_envelope&.from&.email
    end

    def sent_to
      SparrowMail::Adapters::Test.last_envelope&.to&.map(&:email)
    end

    def sent_subject
      SparrowMail::Adapters::Test.last_envelope&.subject
    end

    def sent_reply_to
      SparrowMail::Adapters::Test.last_envelope&.reply_to&.map(&:email)
    end
  end
end
