# frozen_string_literal: true

require_relative "base"

module SparrowMail
  module Adapters
    # SendGrid v3.
    #
    #   config.adapter  = :sendgrid
    #   config.settings = {api_key: ENV["SENDGRID_API_KEY"]}
    #
    # SendGrid has a real per-request sandbox (`mail_settings.sandbox_mode`),
    # which validates the whole request and delivers nothing, so sandbox sends
    # still exercise the full path.
    #
    # Mapping notes: tags become `categories`, metadata becomes `custom_args`,
    # and SendGrid answers a successful send with 202 and an empty body, putting
    # the message id in the X-Message-Id header.
    class SendGrid < Base
      adapter_name :sendgrid
      display_name "SendGrid"
      required_settings :api_key

      DEFAULT_BASE_URL = "https://api.sendgrid.com/"
      SEND_PATH = "v3/mail/send"
      MESSAGE_ID_HEADER = "x-message-id"

      def self.native_sandbox?
        true
      end

      def deliver_envelope(envelope)
        response = http.post_json(SEND_PATH, payload(envelope))

        unless response.success?
          raise_for_response(
            status: response.status,
            payload: response.payload,
            envelope: envelope
          )
        end

        success_result(envelope, message_id: response.header(MESSAGE_ID_HEADER))
      end

      private

      def http
        @http ||= http_client(
          base_url: settings.fetch(:base_url, DEFAULT_BASE_URL),
          headers: {
            "Authorization" => "Bearer #{settings[:api_key]}",
            "Accept" => "application/json"
          }
        )
      end

      def payload(envelope)
        body = {
          "personalizations" => [personalization(envelope)],
          "from" => address(envelope.from),
          "subject" => envelope.subject.to_s,
          "content" => content(envelope)
        }

        body["reply_to"] = address(envelope.reply_to.first) if envelope.reply_to.any?
        body["headers"] = envelope.headers unless envelope.headers.empty?
        body["categories"] = envelope.tags if envelope.tags.any?
        body["attachments"] = envelope.attachments.map { |a| attachment(a) } if envelope.attachments?
        body["mail_settings"] = {"sandbox_mode" => {"enable" => true}} if envelope.sandbox?

        body
      end

      def personalization(envelope)
        personalization = {"to" => envelope.to.map { |a| address(a) }}
        personalization["cc"] = envelope.cc.map { |a| address(a) } if envelope.cc.any?
        personalization["bcc"] = envelope.bcc.map { |a| address(a) } if envelope.bcc.any?
        personalization["custom_args"] = stringify(envelope.metadata) if envelope.metadata.any?
        personalization
      end

      # SendGrid requires text/plain before text/html when both are present.
      def content(envelope)
        parts = []
        parts << {"type" => "text/plain", "value" => envelope.text_body} if envelope.text_body
        parts << {"type" => "text/html", "value" => envelope.html_body} if envelope.html_body
        parts
      end

      def address(addr)
        {"email" => addr.email}.tap do |hash|
          hash["name"] = addr.name if addr.name && !addr.name.empty?
        end
      end

      def attachment(attachment)
        {
          "content" => attachment.base64_content,
          "filename" => attachment.filename,
          "type" => attachment.mime_type,
          "disposition" => attachment.inline? ? "inline" : "attachment"
        }.tap do |part|
          part["content_id"] = attachment.content_id if attachment.inline? && attachment.content_id
        end
      end

      def stringify(hash)
        hash.to_h { |key, value| [key.to_s, value.to_s] }
      end
    end
  end
end
