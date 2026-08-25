# frozen_string_literal: true

module SparrowPay
  module Console
    # What the panel says, and what the hub's Payments card says.
    #
    # Two stores are involved, which is not tidy but is honest about where the
    # values actually have to live:
    #
    #   sparrow_pay:   this gem's own settings, applied in the engine
    #   <processor>:   the processor's keys, where Pay already reads them
    #
    # Both are top-level keys named after whoever reads them, which is the rule
    # everywhere in this console. The second is not ours to place: Pay has
    # looked its keys up there since long before this console existed, and a
    # panel that relocated them would write a file Pay cannot see.
    #
    # Names no processor, like everything else outside the two seams. What it
    # reports about one it learned from Pay or from configuration.
    #
    # Loaded from console_engine.rb, which is only required when sparrow_ui is
    # present -- so referring to SparrowUi::Console::Settings here is safe in a
    # way it would not be from anywhere else in this gem.
    class Report
      # Reads the CREDENTIALS, not SparrowPay.config, and the difference is the
      # whole reason this class takes no configuration object.
      #
      # The engine applies these settings over its defaults at boot, so the live
      # configuration is whatever was true when the server started. This page is
      # where they are edited. A card fed from the live configuration would go
      # on saying "Not set up" for as long as the process lives, seconds after
      # the developer set it up -- and the one they would then distrust is the
      # panel, not the badge.
      def initialize(settings = ::SparrowUi::Console::Settings)
        @settings = settings
      end

      attr_reader :settings

      def stored
        @stored ||= settings.read(SparrowPay::CREDENTIALS_KEY)
      end

      # Which processor this application charges through, as configured.
      def processor
        value = stored[:default_processor].to_s

        value.empty? ? nil : value.to_sym
      end

      # Whether anybody may read or change billing. Unset means nobody, which is
      # the right way round for an application that has not decided.

      # The credentials Pay wants for it, each reduced to whether it is set.
      # NEVER a value: a key on a page is a key in a screenshot, and a key that
      # has been photographed has to be rotated.
      def credentials
        return [] if processor.nil?

        masked = settings.for_display(processor)

        Processors.fields_for(processor).map do |field|
          value = masked[field]

          {
            name: field,
            secret: settings.secret?(field),
            set: value.is_a?(Hash) ? value[:set] : !value.to_s.empty?
          }
        end
      end

      def findings
        [no_processor, unsupported_processor, missing_credentials].compact
      end

      # Rolled up for the hub. A plain Hash rather than a
      # SparrowUi::Console::Status, matching the other modules: the registry
      # coerces, and keeping the shape dumb means this method still works if it
      # is ever read by something that is not the console.
      def status
        return {state: :unconfigured, detail: "No processor is set, so nothing can be charged."} if processor.nil?

        blocking = findings.find { |finding| finding[:level] == :error }
        return {state: :attention, detail: "#{blocking[:title]}."} if blocking

        warning = findings.find { |finding| finding[:level] == :warning }
        return {state: :attention, detail: "#{warning[:title]}."} if warning

        {state: :ready, detail: "Charging through #{Processors.label_for(processor)}."}
      end

      private

      def no_processor
        return if processor

        {
          level: :error,
          title: "No processor is set",
          detail: "Pay can talk to several and will not pick one for you. Until this is " \
                  "set, no organization can be given a customer record and no checkout " \
                  "can start."
        }
      end

      # A processor named in configuration that Pay does not run. Worth its own
      # finding because the symptom otherwise appears a long way from the cause
      # -- the first checkout raises about an unknown processor.
      def unsupported_processor
        return if processor.nil?
        return if Processors.known?(processor)

        {
          level: :error,
          title: "#{Processors.label_for(processor)} is not a processor Pay runs",
          detail: "Pay offers: #{Processors.names.map { |name| Processors.label_for(name) }.join(", ")}."
        }
      end

      def missing_credentials
        return if processor.nil?

        # Also covers a processor whose client gem is absent: Pay exposes no
        # readers for it, so there are no fields, so nothing is missing. The
        # panel says the gem is not installed, which is the useful sentence.
        missing = credentials.reject { |field| field[:set] }
        return if missing.empty?

        {
          level: :error,
          title: "#{Processors.label_for(processor)} is missing #{missing.size} of its settings",
          detail: "Pay reads #{missing.map { |field| field[:name] }.join(", ")} from your " \
                  "credentials and finds nothing. Calls to the processor will fail to " \
                  "authenticate, and webhooks will fail to verify."
        }
      end
    end
  end
end
