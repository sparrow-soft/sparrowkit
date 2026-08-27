# frozen_string_literal: true

require_relative "base"

module SparrowMail
  module Adapters
    # Postmark.
    #
    #   config.adapter  = :postmark
    #   config.settings = {api_key: ENV["POSTMARK_SERVER_TOKEN"]}
    #
    # `api_key` is Postmark's *Server* API token — the only credential
    # sending needs, sent as `X-Postmark-Server-Token`. Postmark also issues
    # an *Account* API token, for account-level calls (managing servers,
    # domains, templates) that this adapter does not make. An optional
    # `account_token` setting is accepted and preserved, reserved for such
    # operations if this gem adds them later — same treatment the SES
    # adapter gives `access_key_id`/`secret_access_key`: not in
    # `required_settings`, so it is never required and never rendered as a
    # field in the control panel. Set it by hand in credentials or an
    # initializer.
    #
    # Sandbox mode swaps in Postmark's documented test token, which makes the
    # API validate the message fully and deliver nothing. That is a real
    # provider sandbox, so the request is still made and the whole path is
    # exercised.
    #
    # Two mapping notes, both documented in the README's provider table:
    #
    #   * Postmark carries a single Tag. When several are set, the first
    #     becomes the Tag so Postmark's own filtering works, and the full list
    #     is preserved under the `sparrow_tags` metadata key rather than
    #     silently dropped.
    #   * Postmark takes recipients as comma-separated strings, not arrays.
    class Postmark < Base
      adapter_name :postmark
      display_name "Postmark"
      required_settings :api_key

      DEFAULT_BASE_URL = "https://api.postmarkapp.com/"
      SEND_PATH = "email"

      # Postmark's documented token for validating without delivering.
      SANDBOX_TOKEN = "POSTMARK_API_TEST"

      # Postmark models streams itself, and creates these two by default on
      # every server: "outbound" for transactional mail, "broadcast" for bulk.
      # A stream configured with its own :message_stream overrides this.
      DEFAULT_MESSAGE_STREAMS = {
        transactional: "outbound",
        broadcast: "broadcast"
      }.freeze

      # The full tag list, since Postmark's own Tag field holds only one.
      TAGS_METADATA_KEY = "sparrow_tags"

      # Postmark reports the interesting failures with its own numeric code
      # rather than a distinct HTTP status, so classification reads the code.
      INACTIVE_RECIPIENT = 406
      INVALID_EMAIL_REQUEST = 300
      SENDER_SIGNATURE_CODES = [400, 401, 402].freeze
      RATE_LIMITED = 429

      def self.native_sandbox?
        true
      end

      # Postmark keeps a separate reputation per message stream on one server,
      # so the stream id belongs in the identity and one API key is genuinely
      # enough to keep bulk and transactional apart.
      def sending_identity(stream)
        super + [message_stream_for_name(stream)]
      end

      def message_stream_for_name(stream)
        settings[:message_stream] ||
          DEFAULT_MESSAGE_STREAMS.fetch(stream, stream.to_s)
      end

      def deliver_envelope(envelope)
        response = http(envelope).post_json(SEND_PATH, payload(envelope))
        json = response.json

        unless response.success?
          raise_for_response(
            status: response.status,
            payload: response.payload,
            envelope: envelope,
            provider_code: json.is_a?(Hash) ? json["ErrorCode"] : nil
          )
        end

        success_result(envelope, message_id: json.is_a?(Hash) ? json["MessageID"] : nil)
      end

      private

      def http(envelope)
        http_client(
          base_url: settings.fetch(:base_url, DEFAULT_BASE_URL),
          headers: {
            "X-Postmark-Server-Token" => server_token(envelope),
            "Accept" => "application/json"
          }
        )
      end

      def server_token(envelope)
        envelope.sandbox? ? SANDBOX_TOKEN : settings[:api_key]
      end

      def raise_for_response(status:, payload:, envelope:, provider_code: nil)
        error_class = error_class_for(status, provider_code)

        raise error_class.new(
          nil,
          adapter: self.class.adapter_name,
          status_code: status,
          provider_code: provider_code,
          provider_message: Redactor.provider_message(payload, envelope: envelope),
          recipients: envelope.all_recipients.size
        )
      end

      def error_class_for(status, code)
        case code
        when INACTIVE_RECIPIENT, INVALID_EMAIL_REQUEST then InvalidRecipientError
        when *SENDER_SIGNATURE_CODES then AuthenticationError
        when RATE_LIMITED then RateLimitError
        else self.class.error_for_status(status)
        end
      end

      def payload(envelope)
        body = {
          "From" => envelope.from.to_s,
          "To" => join(envelope.to),
          "Subject" => envelope.subject.to_s,
          "MessageStream" => message_stream_for(envelope)
        }

        body["Cc"] = join(envelope.cc) if envelope.cc.any?
        body["Bcc"] = join(envelope.bcc) if envelope.bcc.any?
        body["ReplyTo"] = join(envelope.reply_to) if envelope.reply_to.any?
        body["TextBody"] = envelope.text_body if envelope.text_body
        body["HtmlBody"] = envelope.html_body if envelope.html_body
        body["Tag"] = envelope.tags.first if envelope.tags.any?
        body["Headers"] = headers(envelope) unless envelope.headers.empty?
        body["Attachments"] = envelope.attachments.map { |a| attachment(a) } if envelope.attachments?

        metadata = metadata(envelope)
        body["Metadata"] = metadata unless metadata.empty?

        body
      end

      # An explicitly configured stream id wins; otherwise Postmark's own
      # default for this kind of mail. Sending bulk down "outbound" is what
      # Postmark suspends accounts for, so the fallback is deliberately not a
      # single hardcoded value.
      def message_stream_for(envelope)
        message_stream_for_name(envelope.stream)
      end

      def metadata(envelope)
        envelope.metadata.dup.tap do |metadata|
          metadata[TAGS_METADATA_KEY] = envelope.tags.join(",") if envelope.tags.any?
        end
      end

      def headers(envelope)
        envelope.headers.map { |name, value| {"Name" => name, "Value" => value} }
      end

      def attachment(attachment)
        {
          "Name" => attachment.filename,
          "Content" => attachment.base64_content,
          "ContentType" => attachment.mime_type
        }.tap do |part|
          part["ContentID"] = "cid:#{attachment.content_id}" if attachment.inline?
        end
      end

      def join(addresses)
        addresses.join(", ")
      end
    end
  end
end
