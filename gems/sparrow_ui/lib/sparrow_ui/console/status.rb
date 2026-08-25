# frozen_string_literal: true

module SparrowUi
  module Console
    # One module's answer to "is this ready?", for the card on the hub.
    #
    # Three states and a sentence. Deliberately not a list of findings: the hub
    # says whether a module needs attention, and the panel says what about it.
    # A summary rich enough to explain itself would be a second panel on the
    # front page, and would need sparrow_ui to learn what a passkey is.
    #
    # A module builds one however it likes -- sparrow_mail's comes from its own
    # Console::Report, which knows things a form does not.
    Status = Struct.new(:state, :detail)

    # Reopened rather than written as a block on the line above, because the
    # constants below are constants: defining one inside a `Struct.new do ... end`
    # block actually defines it on the enclosing scope, not on the struct, so
    # `Status::READY` would not resolve while `Console::READY` quietly would.
    class Status
      READY = :ready              # configured, nothing to do
      ATTENTION = :attention      # usable, but something is worth looking at
      UNCONFIGURED = :unconfigured # will not work until somebody sets it up
      UNKNOWN = :unknown          # the module did not say, or raised trying

      STATES = [READY, ATTENTION, UNCONFIGURED, UNKNOWN].freeze

      def self.ready(detail = nil) = new(state: READY, detail: detail)

      def self.attention(detail) = new(state: ATTENTION, detail: detail)

      def self.unconfigured(detail) = new(state: UNCONFIGURED, detail: detail)

      def self.unknown(detail = nil) = new(state: UNKNOWN, detail: detail)

      # Accepts what a module can actually produce.
      #
      # Every SparrowKit module is loaded in production, and sparrow_ui is not
      # -- it is a development-group gem, so `SparrowUi::Console::Status` is an
      # undefined constant on a production box. A module that named this class
      # to describe itself would raise on boot at the one moment nobody is
      # watching. So modules hand back `{state: :ready, detail: "..."}`, a Hash
      # they can build without knowing this gem exists, and the coercion happens
      # here where the constant is by definition loaded.
      #
      # An unrecognised state becomes UNKNOWN rather than raising. The caller is
      # rendering the front page of a console for three modules; one of them
      # returning nonsense should cost that module its badge, not the page.
      def self.from(value)
        return value if value.is_a?(Status)

        # `is_a?(Hash)`, not `respond_to?(:[])`. A String answers `[]` too, and
        # answers it by raising TypeError on a Symbol -- so the loose check
        # turned a module returning "ready" into an exception thrown from the
        # method whose entire job is to not do that.
        return unknown unless value.is_a?(Hash)

        state = value[:state] || value["state"]
        detail = value[:detail] || value["detail"]
        state = state.to_sym if state.respond_to?(:to_sym)

        STATES.include?(state) ? new(state: state, detail: detail) : unknown(detail)
      end

      def ready? = state == READY

      def needs_attention? = state == ATTENTION

      def unconfigured? = state == UNCONFIGURED

      def known? = state != UNKNOWN

      # A word, for the badge. Colour is never the only signal: WCAG 1.4.1, and
      # a coloured dot tells a colour-blind reader nothing at all.
      def label
        case state
        when READY then "Ready"
        when ATTENTION then "Check this"
        when UNCONFIGURED then "Not set up"
        else "Unknown"
        end
      end
    end
  end
end
