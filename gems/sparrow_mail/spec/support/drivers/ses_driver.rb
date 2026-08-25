# frozen_string_literal: true

module Drivers
  # Drives the SES adapter through WebMock. The AWS SDK issues its requests over
  # Net::HTTP, so the same interception that works for the JSON APIs works here,
  # and the request count includes anything the SDK would have retried on its
  # own — which is exactly what needs watching.
  class SESDriver < SparrowMail::Conformance::HttpDriver
    REGION = "us-east-1"

    def settings
      {
        region: REGION,
        access_key_id: "AKIACONFORMANCEKEY",
        secret_access_key: "conformance-secret-access-key"
      }
    end

    def endpoint
      "https://email.#{REGION}.amazonaws.com/v2/email/outbound-emails"
    end

    def success_response(message_id)
      [200, json_headers, JSON.generate({"MessageId" => message_id})]
    end

    def failure_response(kind)
      case kind
      when :authentication
        aws_error(403, "AccessDeniedException", "User is not authorized to perform ses:SendEmail")
      when :invalid_recipient
        aws_error(400, "MessageRejected", "Email address is not verified")
      when :rate_limit
        aws_error(429, "TooManyRequestsException", "Maximum sending rate exceeded")
      when :server_error
        aws_error(500, "InternalServiceErrorException", "Internal service error")
      else
        raise ArgumentError, "unsupported failure kind #{kind.inspect}"
      end
    end

    # The AWS SDK builds its exception message from the `message` field, so the
    # echoed text arrives through an allowlisted route and must be scrubbed.
    def echo_response(text)
      aws_error(400, "MessageRejected", "Message content rejected: #{text}")
    end

    def sent_metadata
      tags = request_json&.fetch("EmailTags", nil)
      return nil if tags.nil?

      tags.to_h { |tag| [tag["Name"], tag["Value"]] }
    end

    # No tag or metadata concept. The control headers used to reach these
    # providers inside the raw MIME, which was leakage rather than support.
    def sent_tags
      nil
    end

    def sent_headers
      mime = raw_mime
      return nil if mime.nil?

      mime.split(/\r?\n\r?\n/, 2).first.to_s.lines.filter_map do |line|
        name, value = line.split(":", 2)
        [name.strip, value.strip] if name && value && name.start_with?("X-App")
      end.to_h
    end

    def sent_from
      request_json&.fetch("FromEmailAddress", nil)
    end

    def sent_to
      request_json&.dig("Destination", "ToAddresses")
    end

    def sent_subject
      raw_mime&.[](/^Subject:\s*(.+)$/, 1)
    end

    def sent_reply_to
      value = raw_mime&.[](/^Reply-To:\s*(.+)$/, 1)
      value && [value]
    end

    private

    def request_json
      body = last_body
      return nil if body.nil? || body.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end

    def raw_mime
      encoded = request_json&.dig("Content", "Raw", "Data")
      return nil if encoded.nil?

      Base64.decode64(encoded)
    end

    def aws_error(status, type, message)
      [
        status,
        json_headers.merge("x-amzn-ErrorType" => "#{type}:"),
        JSON.generate({"__type" => type, "message" => message})
      ]
    end

    def json_headers
      {"Content-Type" => "application/x-amz-json-1.1"}
    end
  end
end
