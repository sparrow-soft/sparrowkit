# frozen_string_literal: true

require "base64"
require_relative "base"
require_relative "../transport/multipart"

module SparrowMail
  module Adapters
    # Mailgun.
    #
    #   config.adapter  = :mailgun
    #   config.settings = {
    #     api_key: ENV["MAILGUN_API_KEY"],
    #     domain:  "mg.example.com",
    #     base_url: "https://api.eu.mailgun.net/"   # EU region, optional
    #   }
    #
    # Mailgun's send endpoint is a form rather than JSON, and this adapter always
    # posts multipart/form-data — one code path whether or not there are
    # attachments, rather than two that diverge.
    #
    # Mapping notes: tags become repeated `o:tag` fields, metadata becomes
    # `v:`-prefixed fields, custom headers become `h:`-prefixed fields, and
    # sandbox mode sets Mailgun's own `o:testmode`, which accepts and drops the
    # message.
    class Mailgun < Base
      adapter_name :mailgun
      display_name "Mailgun"
      required_settings :api_key, :domain

      DEFAULT_BASE_URL = "https://api.mailgun.net/"

      def self.native_sandbox?
        true
      end

      # A Mailgun account can hold several sending domains, and each carries
      # its own reputation, so a subdomain for bulk is real separation.
      def self.identity_settings
        [:api_key, :domain]
      end

      def deliver_envelope(envelope)
        response = http.post_multipart(send_path, fields(envelope))

        unless response.success?
          raise_for_response(
            status: response.status,
            payload: response.payload,
            envelope: envelope
          )
        end

        json = response.json
        success_result(envelope, message_id: json.is_a?(Hash) ? json["id"] : nil)
      end

      private

      def send_path
        "v3/#{settings[:domain]}/messages"
      end

      def http
        @http ||= http_client(
          base_url: settings.fetch(:base_url, DEFAULT_BASE_URL),
          headers: {
            "Authorization" => "Basic #{basic_auth}",
            "Accept" => "application/json"
          }
        )
      end

      def basic_auth
        Base64.strict_encode64("api:#{settings[:api_key]}")
      end

      def fields(envelope)
        fields = {
          "from" => envelope.from.to_s,
          "to" => envelope.to.map(&:to_s),
          "subject" => envelope.subject.to_s
        }

        fields["cc"] = envelope.cc.map(&:to_s) if envelope.cc.any?
        fields["bcc"] = envelope.bcc.map(&:to_s) if envelope.bcc.any?
        fields["h:Reply-To"] = envelope.reply_to.join(", ") if envelope.reply_to.any?
        fields["text"] = envelope.text_body if envelope.text_body
        fields["html"] = envelope.html_body if envelope.html_body
        fields["o:tag"] = envelope.tags if envelope.tags.any?
        fields["o:testmode"] = "yes" if envelope.sandbox?

        envelope.headers.each { |name, value| fields["h:#{name}"] = value }
        envelope.metadata.each { |key, value| fields["v:#{key}"] = value.to_s }

        add_attachments(fields, envelope)
        fields
      end

      def add_attachments(fields, envelope)
        return unless envelope.attachments?

        inline, attached = envelope.attachments.partition(&:inline?)

        fields["attachment"] = attached.map { |a| file_part(a) } if attached.any?
        fields["inline"] = inline.map { |a| file_part(a) } if inline.any?
      end

      def file_part(attachment)
        Transport::Multipart::FilePart.new(
          attachment.filename,
          attachment.mime_type,
          attachment.content
        )
      end
    end
  end
end
