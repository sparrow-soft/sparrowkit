# frozen_string_literal: true

module SparrowMail
  module Transport
    # Enough multipart/form-data to satisfy Mailgun, which is the only provider
    # here whose send endpoint is a form rather than JSON.
    module Multipart
      FilePart = Struct.new(:filename, :content_type, :content) do
        # Attachment content is message content.
        def inspect
          "#<SparrowMail::Transport::Multipart::FilePart filename=#{filename.inspect} " \
            "content_type=#{content_type.inspect} content=[redacted]>"
        end
        alias_method :to_s, :inspect
      end

      class << self
        def encode(fields, boundary)
          parts = fields.flat_map do |name, value|
            # Explicitly, not Array(): FilePart is a Struct, and Array() on a
            # Struct explodes it into its members, silently turning one file
            # part into three plain fields.
            values = value.is_a?(Array) ? value : [value]

            values.map { |item| part_for(name, item, boundary) }
          end

          parts.join.b + "--#{boundary}--\r\n".b
        end

        private

        # Every part is assembled as BYTES, not text.
        #
        # A multipart body is one message carrying two kinds of thing: headers
        # and text fields, which are UTF-8, and attachment content, which is
        # whatever bytes the file happens to hold. Ruby will not concatenate the
        # two -- a UTF-8 subject beside a PNG raises Encoding::CompatibilityError
        # -- so both sides are taken down to binary before they ever meet.
        #
        # This is not theoretical. `parts.join` on a message with a non-ASCII
        # subject and any binary attachment raised, on the Mailgun path, and
        # surfaced as UnknownError -- the class documented as "we do not know
        # what happened". An ASCII-only subject with the same attachment worked,
        # which is why it survived a suite that tested each of them separately.
        def part_for(name, value, boundary)
          if value.is_a?(FilePart)
            headers = "--#{boundary}\r\n" \
              "Content-Disposition: form-data; name=\"#{escape(name)}\"; " \
              "filename=\"#{escape(value.filename)}\"\r\n" \
              "Content-Type: #{escape(value.content_type)}\r\n\r\n"

            headers.b + value.content.to_s.b + "\r\n".b
          else
            headers = "--#{boundary}\r\n" \
              "Content-Disposition: form-data; name=\"#{escape(name)}\"\r\n\r\n"

            headers.b + value.to_s.b + "\r\n".b
          end
        end

        # Applied to every value that lands in a header, not just the filename.
        #
        # It used to escape the filename alone, which left the field name and
        # the content type interpolated raw. Both are reachable: the Mailgun
        # adapter builds field names from an envelope's custom headers and
        # metadata, so a quote and a CRLF in one of those could close the
        # Content-Disposition and write a replacement -- making a part claim to
        # be a different field. The random boundary stops a new part being
        # forged; it does nothing about rewriting the headers of this one.
        def escape(value)
          value.to_s.gsub('"', "%22").tr("\r\n", "  ")
        end
      end
    end
  end
end
