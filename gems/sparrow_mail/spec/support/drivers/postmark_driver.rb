# frozen_string_literal: true

module Drivers
  class PostmarkDriver < SparrowMail::Conformance::HttpDriver
    def settings
      {api_key: "postmark-conformance-token"}
    end

    def endpoint
      "https://api.postmarkapp.com/email"
    end

    def success_response(message_id)
      [200, json_headers, JSON.generate({
        "To" => "person@example.org",
        "SubmittedAt" => "2026-08-08T10:00:00Z",
        "MessageID" => message_id,
        "ErrorCode" => 0,
        "Message" => "OK"
      })]
    end

    def failure_response(kind)
      case kind
      when :authentication
        [401, json_headers, JSON.generate({"ErrorCode" => 401, "Message" => "Bad or missing token"})]
      when :invalid_recipient
        [422, json_headers, JSON.generate({"ErrorCode" => 406, "Message" => "Inactive recipient"})]
      when :rate_limit
        [429, json_headers, JSON.generate({"ErrorCode" => 429, "Message" => "Rate limit exceeded"})]
      when :server_error
        [500, json_headers, JSON.generate({"ErrorCode" => 500, "Message" => "Internal server error"})]
      else
        raise ArgumentError, "unsupported failure kind #{kind.inspect}"
      end
    end

    # `Message` passes the redactor's allowlist; `HtmlBody` does not. Postmark
    # really does echo submitted content back on a validation error, which is
    # what this case exists to model.
    def echo_response(text)
      [
        422,
        json_headers,
        JSON.generate({
          "ErrorCode" => 300,
          "Message" => "Invalid message content: #{text}",
          "HtmlBody" => text
        })
      ]
    end

    def sent_headers
      fields = last_json&.fetch("Headers", nil)
      return nil if fields.nil?

      fields.to_h { |field| [field["Name"], field["Value"]] }
    end

    # Postmark carries one Tag; the adapter preserves the full list in metadata.
    def sent_tags
      raw = last_json&.dig("Metadata", SparrowMail::Adapters::Postmark::TAGS_METADATA_KEY)
      return nil if raw.nil?

      raw.split(",")
    end

    def sent_metadata
      last_json&.fetch("Metadata", nil)
    end

    def sent_stream
      last_json&.fetch("MessageStream", nil)
    end

    def sandbox_marked?
      last_headers["X-Postmark-Server-Token"] ==
        SparrowMail::Adapters::Postmark::SANDBOX_TOKEN
    end

    def sent_from
      last_json&.fetch("From", nil)
    end

    # Postmark takes recipients as a comma-separated string.
    def sent_to
      last_json&.fetch("To", nil)&.split(",")&.map { |a| a[/<([^>]+)>/, 1] || a.strip }
    end

    def sent_subject
      last_json&.fetch("Subject", nil)
    end

    def sent_reply_to
      raw = last_json&.fetch("ReplyTo", nil)
      raw&.split(",")&.map(&:strip)
    end

    private

    def json_headers
      {"Content-Type" => "application/json"}
    end
  end
end
