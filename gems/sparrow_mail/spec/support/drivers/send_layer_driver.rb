# frozen_string_literal: true

module Drivers
  class SendLayerDriver < SparrowMail::Conformance::HttpDriver
    def settings
      {api_key: "sendlayer-conformance-key"}
    end

    def endpoint
      "https://console.sendlayer.com/api/v1/email"
    end

    def success_response(message_id)
      [200, json_headers, JSON.generate({"MessageID" => message_id})]
    end

    def failure_response(kind)
      case kind
      when :authentication
        [401, json_headers, JSON.generate({"Error" => "Invalid API key"})]
      when :invalid_recipient
        [400, json_headers, JSON.generate({"Error" => "Recipient address is not valid"})]
      when :rate_limit
        [429, json_headers, JSON.generate({"Error" => "Too many requests"})]
      when :server_error
        [500, json_headers, JSON.generate({"Error" => "Internal server error"})]
      else
        raise ArgumentError, "unsupported failure kind #{kind.inspect}"
      end
    end

    # `Error` is a key the redactor lets through, `PlainContent` is not. Putting
    # the echoed text in both exercises the allowlist and the scrub pass.
    def echo_response(text)
      [
        400,
        json_headers,
        JSON.generate({
          "Error" => "Message rejected, content was: #{text}",
          "PlainContent" => text
        })
      ]
    end

    def sent_headers
      last_json&.fetch("Headers", nil)
    end

    def sent_tags
      last_json&.fetch("Tags", nil)
    end

    def sent_from
      last_json&.dig("From", "email")
    end

    def sent_to
      last_json&.fetch("To", nil)&.map { |a| a["email"] }
    end

    def sent_subject
      last_json&.fetch("Subject", nil)
    end

    def sent_reply_to
      last_json&.fetch("ReplyTo", nil)&.map { |a| a["email"] }
    end

    private

    def json_headers
      {"Content-Type" => "application/json"}
    end
  end
end
