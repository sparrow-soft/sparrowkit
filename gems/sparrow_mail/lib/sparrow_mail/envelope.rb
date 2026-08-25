# frozen_string_literal: true

require "base64"
require "json"

module SparrowMail
  # A single email address plus its optional display name.
  Address = Struct.new(:email, :name) do
    def to_s
      (name && !name.empty?) ? "#{name} <#{email}>" : email.to_s
    end
  end

  # One attachment, decoded once so every adapter does not decode it again.
  class Attachment
    attr_reader :filename, :mime_type, :content, :content_id

    def initialize(filename:, mime_type:, content:, content_id: nil, inline: false)
      @filename = filename
      @mime_type = mime_type
      @content = content
      @content_id = content_id
      @inline = inline
    end

    def inline?
      @inline
    end

    def base64_content
      Base64.strict_encode64(content.to_s)
    end

    def byte_size
      content.to_s.bytesize
    end

    # Attachment content is message content. It is redacted for the same reason
    # bodies are.
    def inspect
      "#<SparrowMail::Attachment filename=#{filename.inspect} " \
        "mime_type=#{mime_type.inspect} bytes=#{byte_size} " \
        "inline=#{inline?} content=[redacted]>"
    end
    alias_method :to_s, :inspect
  end

  # A Mail::Message normalised exactly once, so that adapters only ever map an
  # already-parsed payload onto their provider's API.
  #
  # Three things follow from putting this in the core rather than in each
  # adapter. Multipart handling and attachment decoding are written and tested
  # once instead of seven times. Adapters stay thin enough to review in one
  # sitting. And the redaction that keeps message bodies out of logs lives at a
  # single chokepoint, rather than depending on every adapter author
  # remembering it.
  class Envelope
    # Callers set these on the Mail::Message to reach provider features that
    # every provider spells differently. The envelope translates them, then
    # strips them, so they never go out as raw headers.
    TAGS_HEADER = "X-Sparrow-Tags"
    METADATA_HEADER = "X-Sparrow-Metadata"
    STREAM_HEADER = "X-Sparrow-Stream"
    CONTROL_HEADERS = [TAGS_HEADER, METADATA_HEADER, STREAM_HEADER].freeze

    # Mail that is not explicitly bulk is transactional. Getting this default
    # the other way round would put sign-in codes on a bulk reputation.
    DEFAULT_STREAM = :transactional

    # Headers the envelope already models as first-class fields, plus the MIME
    # structure headers that belong to whatever transport actually serialises
    # the message. Passing these through as custom headers would duplicate or
    # corrupt them.
    MODELLED_HEADERS = %w[
      from to cc bcc subject reply-to
      content-type content-transfer-encoding mime-version
      date message-id
    ].freeze

    attr_reader :from, :to, :cc, :bcc, :reply_to, :subject,
      :text_body, :html_body, :attachments, :headers, :tags, :metadata, :stream, :mail

    class << self
      # Reads just the stream off a message, without the cost of building a
      # whole envelope. SparrowMail needs this before it can choose which
      # adapter to hand the message to.
      def stream_from(mail)
        return mail.stream if mail.is_a?(Envelope)

        raw = mail.header[STREAM_HEADER]&.value.to_s.strip.downcase
        raw.empty? ? DEFAULT_STREAM : raw.to_sym
      end

      def from_mail(mail, sandbox: false)
        new(
          from: address_from(mail[:from]),
          to: addresses_from(mail[:to]),
          cc: addresses_from(mail[:cc]),
          bcc: addresses_from(mail[:bcc]),
          reply_to: addresses_from(mail[:reply_to]),
          subject: mail.subject,
          text_body: text_body_from(mail),
          html_body: html_body_from(mail),
          attachments: attachments_from(mail),
          headers: headers_from(mail),
          tags: tags_from(mail),
          metadata: metadata_from(mail),
          stream: stream_from(mail),
          sandbox: sandbox,
          mail: mail
        )
      end

      private

      def address_from(field)
        addresses_from(field).first
      end

      def addresses_from(field)
        return [] if field.nil?

        Array(field.addrs).map do |addr|
          Address.new(addr.address, addr.display_name)
        end
      rescue Mail::Field::IncompleteParseError, NoMethodError
        # A field the `mail` gem could not parse into structured addresses.
        # Fall back to the raw value rather than losing the recipient silently.
        Array(field.value).map { |value| Address.new(value.to_s.strip, nil) }
      end

      def text_body_from(mail)
        if mail.multipart?
          mail.text_part&.decoded
        elsif mail.mime_type.nil? || mail.mime_type == "text/plain"
          presence(mail.body.decoded)
        end
      end

      def html_body_from(mail)
        if mail.multipart?
          mail.html_part&.decoded
        elsif mail.mime_type == "text/html"
          presence(mail.body.decoded)
        end
      end

      def attachments_from(mail)
        mail.attachments.map do |part|
          Attachment.new(
            filename: part.filename,
            mime_type: part.mime_type,
            content: part.body.decoded,
            content_id: part.content_id&.delete("<>"),
            inline: part.content_disposition.to_s.strip.downcase.start_with?("inline")
          )
        end
      end

      def headers_from(mail)
        skip = MODELLED_HEADERS + CONTROL_HEADERS.map(&:downcase)

        mail.header.fields.each_with_object({}) do |field, result|
          next if skip.include?(field.name.to_s.downcase)

          result[field.name.to_s] = field.value.to_s
        end
      end

      def tags_from(mail)
        raw = mail.header[TAGS_HEADER]&.value.to_s
        raw.split(",").map(&:strip).reject(&:empty?)
      end

      def metadata_from(mail)
        raw = mail.header[METADATA_HEADER]&.value.to_s
        return {} if raw.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      rescue JSON::ParserError
        # Malformed metadata is a caller bug, not a reason to fail a sign-in
        # email. Drop it and deliver.
        {}
      end

      def presence(value)
        (value.nil? || value.empty?) ? nil : value
      end
    end

    def initialize(from:, to:, subject: nil, cc: [], bcc: [], reply_to: [],
      text_body: nil, html_body: nil, attachments: [], headers: {},
      tags: [], metadata: {}, stream: DEFAULT_STREAM, sandbox: false, mail: nil)
      @from = from
      @to = to
      @cc = cc
      @bcc = bcc
      @reply_to = reply_to
      @subject = subject
      @text_body = text_body
      @html_body = html_body
      @attachments = attachments
      @headers = headers
      @tags = tags
      @metadata = metadata
      @stream = stream
      @sandbox = sandbox
      @mail = mail

      validate!
    end

    def sandbox?
      @sandbox
    end

    def all_recipients
      to + cc + bcc
    end

    def attachments?
      !attachments.empty?
    end

    # The message serialised, with the X-Sparrow-* control headers removed.
    # Transports that post raw MIME (SMTP, Amazon SES) use this and get
    # attachments, encoding and threading headers for free.
    #
    # The control headers are stripped here for the same reason they are
    # stripped from #headers: they are this gem's private vocabulary for
    # reaching provider features, not something to publish to every receiving
    # mail server. Without this, "control headers never go out as raw headers"
    # would be true of the JSON adapters and quietly false of these two.
    def to_mime
      @to_mime ||= build_mime
    end

    # Everything here is routing metadata. Nothing here is message content.
    # This is the only shape of envelope information that reaches a log line.
    def log_summary
      {
        recipients: all_recipients.size,
        attachments: attachments.size,
        tags: tags,
        stream: stream,
        sandbox: sandbox?
      }
    end

    def inspect
      "#<SparrowMail::Envelope recipients=#{all_recipients.size} " \
        "attachments=#{attachments.size} tags=#{tags.inspect} " \
        "stream=#{stream} sandbox=#{sandbox?} subject=[redacted] " \
        "text_body=[redacted] html_body=[redacted]>"
    end
    alias_method :to_s, :inspect

    private

    def build_mime
      raw = mail.to_s
      return raw if CONTROL_HEADERS.none? { |header| mail.header[header] }

      # Re-parsed rather than mutated, so that stripping headers for the wire
      # cannot alter the caller's own Mail::Message.
      stripped = Mail.new(raw)
      CONTROL_HEADERS.each { |header| stripped.header[header] = nil }
      stripped.to_s
    end

    def validate!
      raise ConfigurationError, "message has no sender (From is empty)" if from.nil?

      if all_recipients.empty?
        raise ConfigurationError, "message has no recipient (To, Cc and Bcc are all empty)"
      end
    end
  end
end
