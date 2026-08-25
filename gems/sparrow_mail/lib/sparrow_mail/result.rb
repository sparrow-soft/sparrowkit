# frozen_string_literal: true

module SparrowMail
  # What a send returns.
  #
  # Deliberately narrow. There is no accessor for the message, the body, or the
  # provider's raw response, because a value object that can hold body content
  # eventually ends up in a log line or an error report. Everything here is safe
  # to serialise anywhere.
  #
  # Note the difference between `success?` and `delivered?`. A message withheld
  # in sandbox mode is a success that was not delivered; conflating the two
  # would make every staging run look like a failure.
  class Result
    attr_reader :adapter, :message_id, :recipients, :duration_ms, :stream, :error

    def self.failed(error, recipients: nil, duration_ms: nil, sandbox: false, stream: nil)
      new(
        adapter: error.adapter,
        recipients: recipients || error.recipients,
        duration_ms: duration_ms,
        sandbox: sandbox,
        stream: stream,
        delivered: false,
        error: error
      )
    end

    def initialize(adapter:, message_id: nil, recipients: nil, duration_ms: nil,
      stream: nil, sandbox: false, delivered: true, error: nil)
      @adapter = adapter
      @message_id = message_id
      @recipients = recipients
      @duration_ms = duration_ms
      @stream = stream
      @sandbox = sandbox
      @delivered = delivered
      @error = error
    end

    def success?
      error.nil?
    end

    def failure?
      !success?
    end

    def sandbox?
      @sandbox
    end

    def delivered?
      @delivered
    end

    # The failure category, one of SparrowMail::DeliveryError::CATEGORIES, or
    # nil on success. This is what a caller branches on: it is the gem's
    # vocabulary rather than any provider's, so it survives switching provider.
    def category
      error&.category
    end

    # Returns a copy with some fields replaced. The core uses this to stamp on
    # what it, rather than the adapter, is authoritative about: elapsed time and
    # whether the send was in sandbox mode.
    def with(**changes)
      self.class.new(**to_h.merge(error: error).merge(changes))
    end

    def to_h
      {
        adapter: adapter,
        message_id: message_id,
        recipients: recipients,
        duration_ms: duration_ms,
        stream: stream,
        sandbox: sandbox?,
        delivered: delivered?
      }.tap do |hash|
        hash[:error] = error.to_h if error
      end
    end

    def inspect
      fields = to_h.map { |key, value| "#{key}=#{value.inspect}" }.join(" ")

      "#<SparrowMail::Result #{fields}>"
    end
    alias_method :to_s, :inspect
  end
end
