# frozen_string_literal: true

require "net/http"
require "uri"
require "json"
require "securerandom"

module SparrowMail
  module Transport
    # A deliberately small HTTP client for the API adapters.
    #
    # It exists for one reason that is not "avoid a dependency": Net::HTTP
    # retries idempotent requests once by default when a connection is reset
    # (max_retries defaults to 1). A POST to a send endpoint is not idempotent,
    # and that quiet single retry is exactly the behaviour the never-retry rule
    # forbids. Every client this gem builds switches it off explicitly, in one
    # place, where a spec can assert on it.
    class Http
      DEFAULT_OPEN_TIMEOUT = 5
      DEFAULT_READ_TIMEOUT = 15

      # A response, with the provider's raw body deliberately kept out of
      # #inspect: a validation error commonly echoes the submitted message back,
      # so a Response printed by an error reporter would leak a body.
      # Callers pass #body to SparrowMail::Redactor, never to a log.
      Response = Struct.new(:status, :headers, :body) do
        def success?
          status.between?(200, 299)
        end

        def json
          return nil if body.nil? || body.empty?

          JSON.parse(body)
        rescue JSON::ParserError
          nil
        end

        # The provider's diagnostics if we can find them, the raw body if we
        # cannot. Either way it goes through the redactor before it is used.
        def payload
          json || body
        end

        def header(name)
          headers[name.downcase]
        end

        def inspect
          "#<SparrowMail::Transport::Http::Response status=#{status} body=[redacted]>"
        end
        alias_method :to_s, :inspect
      end

      attr_reader :base_url

      def initialize(base_url:, open_timeout: DEFAULT_OPEN_TIMEOUT,
        read_timeout: DEFAULT_READ_TIMEOUT, headers: {})
        @base_url = base_url
        @open_timeout = open_timeout
        @read_timeout = read_timeout
        @headers = headers
      end

      def post_json(path, payload, headers: {})
        post(path, body: JSON.generate(payload), content_type: "application/json", headers: headers)
      end

      # multipart/form-data. `fields` values may be a String, an Array of
      # Strings (repeated field), or a FilePart.
      def post_multipart(path, fields, headers: {})
        boundary = "SparrowMail-#{SecureRandom.hex(16)}"

        post(
          path,
          body: Multipart.encode(fields, boundary),
          content_type: "multipart/form-data; boundary=#{boundary}",
          headers: headers
        )
      end

      def post(path, body:, content_type:, headers: {})
        uri = URI.join(base_url, path)
        request = Net::HTTP::Post.new(uri)
        request["Content-Type"] = content_type
        @headers.merge(headers).each { |name, value| request[name] = value }
        request.body = body

        execute(uri, request)
      end

      private

      def execute(uri, request)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == "https"
        http.open_timeout = @open_timeout
        http.read_timeout = @read_timeout

        # The line this class exists for. Net::HTTP would otherwise silently
        # resend a POST after a connection reset.
        http.max_retries = 0

        response = http.request(request)

        Response.new(
          response.code.to_i,
          response.each_header.to_h,
          response.body
        )
      end
    end
  end
end

require_relative "multipart"
