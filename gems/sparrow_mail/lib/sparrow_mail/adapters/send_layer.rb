# frozen_string_literal: true

require_relative "base"

module SparrowMail
  module Adapters
    # SendLayer.
    #
    # Built first, deliberately: an interface designed against zero
    # implementations is a guess. This is the adapter that proved the shape of
    # Envelope and of deliver_envelope, and every other adapter here was written
    # against the interface it settled.
    #
    #   config.adapter  = :sendlayer
    #   config.settings = {api_key: ENV["SENDLAYER_API_KEY"]}
    #
    # SendLayer has no per-request sandbox, so sandbox mode is handled by the
    # core: nothing is sent and the message is recorded locally.
    class SendLayer < Base
      adapter_name :sendlayer
      display_name "SendLayer"
      required_settings :api_key

      DEFAULT_BASE_URL = "https://console.sendlayer.com/api/v1/"
      SEND_PATH = "email"

      def deliver_envelope(envelope)
        response = http.post_json(SEND_PATH, payload(envelope))

        unless response.success?
          raise_for_response(
            status: response.status,
            payload: response.payload,
            envelope: envelope
          )
        end

        success_result(envelope, message_id: message_id_from(response))
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
          "From" => address(envelope.from),
          "To" => envelope.to.map { |recipient| address(recipient) },
          "Subject" => envelope.subject.to_s,
          "ContentType" => envelope.html_body ? "HTML" : "Plain"
        }

        body["Cc"] = envelope.cc.map { |recipient| address(recipient) } if envelope.cc.any?
        body["Bcc"] = envelope.bcc.map { |recipient| address(recipient) } if envelope.bcc.any?
        body["ReplyTo"] = envelope.reply_to.map { |a| address(a) } if envelope.reply_to.any?
        body["PlainContent"] = envelope.text_body if envelope.text_body
        body["HTMLContent"] = envelope.html_body if envelope.html_body
        body["Tags"] = envelope.tags if envelope.tags.any?
        body["Headers"] = envelope.headers unless envelope.headers.empty?
        body["Attachments"] = envelope.attachments.map { |a| attachment(a) } if envelope.attachments?

        body
      end

      def address(addr)
        {"email" => addr.email}.tap do |hash|
          hash["name"] = addr.name if addr.name && !addr.name.empty?
        end
      end

      def attachment(attachment)
        {
          "FileName" => attachment.filename,
          "FileType" => attachment.mime_type,
          "Content" => attachment.base64_content
        }
      end

      def message_id_from(response)
        json = response.json
        return nil unless json.is_a?(Hash)

        json["MessageID"] || json["MessageId"] || json["message_id"]
      end
    end
  end
end
