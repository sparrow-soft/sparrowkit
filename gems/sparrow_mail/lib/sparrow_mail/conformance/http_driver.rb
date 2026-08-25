# frozen_string_literal: true

require "webmock"
require "json"
require "sparrow_mail/conformance/driver"

module SparrowMail
  module Conformance
    # A conformance driver for adapters that speak HTTP to an API, which is
    # most of them. Subclasses describe their provider in four small methods and
    # inherit request counting, body capture and the network-failure case.
    #
    # Requests are counted through WebMock's matcher block rather than after the
    # fact, so an attempt that raises still counts. That matters: the retry
    # behaviour this suite exists to forbid shows up precisely when a request
    # fails, and a counter that only sees successful requests would miss it.
    class HttpDriver < Driver
      # The exception a dead connection raises. Net::HTTP's own retry, if it
      # were left on, would fire on exactly this.
      NETWORK_EXCEPTION = Errno::ECONNRESET

      def initialize
        @requests = []
      end

      # --- provider description, implemented by subclasses ------------------

      # The URL the adapter posts to, as a String or Regexp.
      def endpoint
        raise NotImplementedError, "#{self.class} must implement #endpoint"
      end

      # [status, headers, body] for an accepted send.
      def success_response(message_id)
        raise NotImplementedError, "#{self.class} must implement #success_response"
      end

      # [status, headers, body] for each failure kind except :network_failure,
      # which this class handles by killing the connection.
      def failure_response(kind)
        raise NotImplementedError, "#{self.class} must implement #failure_response"
      end

      # [status, headers, body] for a rejection that quotes `text` back at us,
      # in both a diagnostic field and a submitted-content field.
      def echo_response(text)
        raise NotImplementedError, "#{self.class} must implement #echo_response"
      end

      # --- driver contract ---------------------------------------------------

      def stub_success(message_id: "conformance-message-id")
        stub(*success_response(message_id))
      end

      def stub_failure(kind)
        if kind == :network_failure
          stub_raising(NETWORK_EXCEPTION)
        else
          stub(*failure_response(kind))
        end
      end

      def stub_echo(text)
        stub(*echo_response(text))
      end

      def request_count
        @requests.size
      end

      def reset!
        WebMock.reset!
        @requests = []
      end

      # --- helpers for subclasses -------------------------------------------

      def last_request
        @requests.last
      end

      def last_body
        last_request&.body
      end

      def last_json
        body = last_body
        return nil if body.nil? || body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        nil
      end

      def last_headers
        last_request&.headers || {}
      end

      private

      def stub(status, headers, body)
        register.to_return(status: status, headers: headers, body: body)
      end

      def stub_raising(exception)
        register.to_raise(exception)
      end

      def register
        captured = @requests

        WebMock.stub_request(:post, endpoint).with { |request|
          captured << request
          true
        }
      end
    end
  end
end
