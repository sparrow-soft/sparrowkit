# frozen_string_literal: true

module Drivers
  class SendGridDriver < SparrowMail::Conformance::HttpDriver
    def settings
      {api_key: "sendgrid-conformance-key"}
    end

    def endpoint
      "https://api.sendgrid.com/v3/mail/send"
    end

    # SendGrid answers an accepted send with 202, an empty body, and the id in
    # a header.
    def success_response(message_id)
      [202, {"X-Message-Id" => message_id}, ""]
    end

    def failure_response(kind)
      case kind
      when :authentication
        [401, json_headers, errors("The provided authorization grant is invalid")]
      when :invalid_recipient
        [400, json_headers, errors("Does not contain a valid address", field: "personalizations.0.to.0.email")]
      when :rate_limit
        [429, json_headers, errors("Too many requests")]
      when :server_error
        [500, json_headers, errors("Internal server error")]
      else
        raise ArgumentError, "unsupported failure kind #{kind.inspect}"
      end
    end

    # `message` and `help` pass the allowlist; `value` does not.
    def echo_response(text)
      [
        400,
        json_headers,
        JSON.generate({
          "errors" => [{
            "message" => "Invalid content: #{text}",
            "field" => "content.0.value",
            "value" => text
          }]
        })
      ]
    end

    def sent_headers
      last_json&.fetch("headers", nil)
    end

    def sent_tags
      last_json&.fetch("categories", nil)
    end

    def sent_metadata
      last_json&.dig("personalizations", 0, "custom_args")
    end

    def sandbox_marked?
      last_json&.dig("mail_settings", "sandbox_mode", "enable") == true
    end

    def sent_from
      last_json&.dig("from", "email")
    end

    def sent_to
      last_json&.dig("personalizations", 0, "to")&.map { |a| a["email"] }
    end

    def sent_subject
      last_json&.fetch("subject", nil)
    end

    def sent_reply_to
      address = last_json&.fetch("reply_to", nil)
      address && [address["email"]]
    end

    private

    def errors(message, field: nil)
      JSON.generate({"errors" => [{"message" => message, "field" => field}.compact]})
    end

    def json_headers
      {"Content-Type" => "application/json"}
    end
  end
end
