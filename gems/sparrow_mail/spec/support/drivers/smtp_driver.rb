# frozen_string_literal: true

module Drivers
  # Drives the SMTP adapter against a real in-process SMTP server rather than a
  # stub, because there is no HTTP layer to intercept and a mocked Net::SMTP
  # would prove nothing about the adapter.
  #
  # "One request" here means one TCP connection, which is what a retry would
  # duplicate.
  class SMTPDriver < SparrowMail::Conformance::Driver
    def initialize
      @server = FakeSmtpServer.new
    end

    attr_reader :server

    def settings
      {
        address: server.address,
        port: server.port,
        user_name: "conformance",
        password: "conformance-password",
        authentication: :plain,
        enable_starttls_auto: false,
        domain: "conformance.local"
      }
    end

    def stub_success(message_id: "conformance-message-id")
      server.queued_id = message_id
    end

    def stub_failure(kind)
      case kind
      when :authentication then server.auth_reply = "535 5.7.8 Authentication credentials invalid\r\n"
      when :invalid_recipient then server.rcpt_to_reply = "550 5.1.1 No such user here\r\n"
      when :rate_limit then server.rcpt_to_reply = "450 4.2.1 Mailbox busy, too many messages\r\n"
      when :server_error then server.data_reply = "554 5.3.0 Transaction failed\r\n"
      when :network_failure then server.hang_up = true
      else raise ArgumentError, "unsupported failure kind #{kind.inspect}"
      end
    end

    # An SMTP server rejects at the end of DATA, by which point it has the whole
    # message and can quote any of it back. Several real ones do.
    def stub_echo(text)
      server.data_reply = "554 5.6.0 Message content rejected: #{text}\r\n"
    end

    def request_count
      server.connection_count
    end

    # SMTP carries the raw message, so every header the caller set arrives,
    # including the X-Sparrow-* control headers.
    def sent_headers
      header_lines.filter_map do |line|
        name, value = line.split(":", 2)
        [name.strip, value.strip] if name && value
      end.to_h
    end

    # No tag or metadata concept. The control headers used to reach these
    # providers inside the raw MIME, which was leakage rather than support.
    def sent_tags
      nil
    end

    # No tag or metadata concept. The control headers used to reach these
    # providers inside the raw MIME, which was leakage rather than support.
    def sent_metadata
      nil
    end

    def reset!
      server.reset!
    end

    def shutdown
      server.shutdown
    end

    def sent_from
      server.deliveries.last&.from
    end

    def sent_to
      server.deliveries.last&.recipients
    end

    def sent_subject
      sent_headers["Subject"]
    end

    def sent_reply_to
      value = sent_headers["Reply-To"]
      value && [value]
    end

    private

    def header_lines
      data = server.deliveries.last&.data
      return [] if data.nil?

      data.split(/\r?\n\r?\n/, 2).first.to_s.lines.map(&:chomp)
    end
  end
end
