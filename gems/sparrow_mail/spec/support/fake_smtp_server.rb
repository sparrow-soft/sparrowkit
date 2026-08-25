# frozen_string_literal: true

require "socket"

# A real SMTP server, in-process, on a real socket.
#
# WebMock cannot stub SMTP, and mocking Net::SMTP would test the mock rather
# than the adapter. This speaks enough of RFC 5321 to be driven by Net::SMTP for
# real, which means the SMTP adapter's conformance run exercises an actual
# connection, an actual AUTH exchange and actual reply codes — including the
# case where the server hangs up mid-conversation.
class FakeSmtpServer
  Delivery = Struct.new(:from, :recipients, :data)

  # Reply codes to send at each stage. nil means "accept".
  attr_accessor :auth_reply, :mail_from_reply, :rcpt_to_reply, :data_reply
  attr_accessor :queued_id, :hang_up
  attr_reader :deliveries, :connection_count

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @deliveries = []
    @connection_count = 0
    @queued_id = "conformance-message-id"
    @hang_up = false
    @thread = Thread.new { accept_loop }
    @thread.abort_on_exception = false
  end

  def port
    @server.addr[1]
  end

  def address
    "127.0.0.1"
  end

  def reset!
    @deliveries = []
    @connection_count = 0
    @auth_reply = nil
    @mail_from_reply = nil
    @rcpt_to_reply = nil
    @data_reply = nil
    @hang_up = false
    @queued_id = "conformance-message-id"
  end

  def shutdown
    @thread&.kill
    @server.close unless @server.closed?
  end

  private

  def accept_loop
    loop do
      socket = @server.accept
      @connection_count += 1
      Thread.new(socket) { |connection| serve(connection) }
    end
  rescue IOError, Errno::EBADF
    # Server closed while blocked in accept. Expected at shutdown.
  end

  def serve(socket)
    if hang_up
      socket.close
      return
    end

    socket.print("220 fake.local ESMTP SparrowMail conformance\r\n")
    delivery = Delivery.new(nil, [], nil)

    while (line = socket.gets)
      command = line.strip

      case command
      when /\AEHLO/i
        socket.print("250-fake.local\r\n250-AUTH PLAIN LOGIN\r\n250 8BITMIME\r\n")
      when /\AHELO/i
        socket.print("250 fake.local\r\n")
      when /\AAUTH\s+PLAIN/i
        # Net::SMTP sends the credentials on the same line or the next one.
        socket.gets if command.split(/\s+/).size < 3
        socket.print(auth_reply || "235 2.7.0 Authentication successful\r\n")
      when /\AAUTH\s+LOGIN/i
        socket.print("334 VXNlcm5hbWU6\r\n")
        socket.gets
        socket.print("334 UGFzc3dvcmQ6\r\n")
        socket.gets
        socket.print(auth_reply || "235 2.7.0 Authentication successful\r\n")
      when /\AMAIL FROM:\s*<([^>]*)>/i
        delivery.from = Regexp.last_match(1)
        socket.print(mail_from_reply || "250 2.1.0 Ok\r\n")
      when /\ARCPT TO:\s*<([^>]*)>/i
        delivery.recipients << Regexp.last_match(1)
        socket.print(rcpt_to_reply || "250 2.1.5 Ok\r\n")
      when /\ADATA\z/i
        socket.print("354 End data with <CR><LF>.<CR><LF>\r\n")
        delivery.data = read_data(socket)
        @deliveries << delivery
        socket.print(data_reply || "250 2.0.0 Ok: queued as #{queued_id}\r\n")
      when /\ARSET\z/i
        socket.print("250 2.0.0 Ok\r\n")
      when /\AQUIT\z/i
        socket.print("221 2.0.0 Bye\r\n")
        break
      else
        socket.print("500 5.5.2 Unrecognised command\r\n")
      end
    end
  rescue IOError, Errno::ECONNRESET, Errno::EPIPE
    # The client went away. Nothing to do.
  ensure
    socket.close unless socket.closed?
  end

  def read_data(socket)
    lines = []

    while (line = socket.gets)
      break if line == ".\r\n" || line == ".\n"

      # RFC 5321 dot-stuffing.
      lines << line.sub(/\A\.\./, ".")
    end

    lines.join
  end
end
