# frozen_string_literal: true

module Drivers
  class MailgunDriver < SparrowMail::Conformance::HttpDriver
    DOMAIN = "mg.example.com"

    def settings
      {api_key: "mailgun-conformance-key", domain: DOMAIN}
    end

    def endpoint
      "https://api.mailgun.net/v3/#{DOMAIN}/messages"
    end

    def success_response(message_id)
      [200, json_headers, JSON.generate({
        "id" => message_id,
        "message" => "Queued. Thank you."
      })]
    end

    def failure_response(kind)
      case kind
      when :authentication
        [401, json_headers, JSON.generate({"message" => "Invalid private key"})]
      when :invalid_recipient
        [400, json_headers, JSON.generate({"message" => "'to' parameter is not a valid address"})]
      when :rate_limit
        [429, json_headers, JSON.generate({"message" => "Too many requests"})]
      when :server_error
        [500, json_headers, JSON.generate({"message" => "Internal server error"})]
      else
        raise ArgumentError, "unsupported failure kind #{kind.inspect}"
      end
    end

    # `message` passes the allowlist; `submitted` does not.
    def echo_response(text)
      [
        400,
        json_headers,
        JSON.generate({
          "message" => "Rejected content: #{text}",
          "submitted" => text
        })
      ]
    end

    def sent_headers
      form.filter_map { |name, value| [name.delete_prefix("h:"), value] if name.start_with?("h:") }
        .to_h
    end

    def sent_tags
      form.filter_map { |name, value| value if name == "o:tag" }
    end

    def sent_metadata
      form.filter_map { |name, value| [name.delete_prefix("v:"), value] if name.start_with?("v:") }
        .to_h
    end

    def sandbox_marked?
      form.any? { |name, value| name == "o:testmode" && value == "yes" }
    end

    # Every field as [name, value], keeping duplicates, since repeated names are
    # how Mailgun expresses lists.
    # The captured body is BYTES, because a multipart body carries binary
    # attachment content beside UTF-8 text and the two cannot share an encoding.
    # Text fields are read back as UTF-8 here so assertions can compare them to
    # ordinary string literals; the split itself stays byte-oriented.
    def form
      body = last_body
      return [] if body.nil? || body.empty?

      body = body.dup.force_encoding(Encoding::BINARY)

      boundary = last_headers["Content-Type"].to_s[/boundary=(\S+)/, 1]
      return [] if boundary.nil?

      body.split("--#{boundary}").filter_map do |part|
        headers, content = part.split("\r\n\r\n", 2)
        next if headers.nil? || content.nil?

        name = headers[/name="([^"]+)"/, 1]
        next if name.nil?

        text = content.sub(/\r\n\z/, "").dup.force_encoding(Encoding::UTF_8)
        text = content.sub(/\r\n\z/, "") unless text.valid_encoding?

        [name.dup.force_encoding(Encoding::UTF_8), text]
      end
    end

    def sent_from
      form.filter_map { |name, value| value if name == "from" }.first
    end

    def sent_to
      values = form.filter_map { |name, value| value if name == "to" }
      return nil if values.empty?

      values.map { |a| a[/<([^>]+)>/, 1] || a.strip }
    end

    def sent_subject
      form.filter_map { |name, value| value if name == "subject" }.first
    end

    def sent_reply_to
      values = form.filter_map { |name, value| value if name == "h:Reply-To" }
      values.empty? ? nil : values
    end

    private

    def json_headers
      {"Content-Type" => "application/json"}
    end
  end
end
