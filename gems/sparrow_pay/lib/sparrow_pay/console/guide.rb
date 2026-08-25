# frozen_string_literal: true

module SparrowPay
  module Console
    # What to do with sparrow_pay once it is configured.
    #
    # Names no processor of its own. Whichever one this application charges
    # through comes out of configuration, and the sentence is built around it --
    # so this file stays inside the rule the seam spec enforces while the text
    # it produces is specific to the reader's application.
    #
    # NO SECRETS. This is written to be pasted into somebody else's chat window.
    class Guide
      def initialize(settings = ::SparrowUi::Console::Settings)
        @settings = settings
        @report = Report.new(settings)
      end

      attr_reader :settings, :report

      def to_h
        {steps: steps, brief: brief}
      end

      # How to USE this, not how to install it. The tables and the mount were
      # done by the installer before this page could be reached.
      def steps
        [
          "# The organization is the customer -- never an account\norganization.payment_processor",
          "# Pay's own API, from there\norganization.payment_processor.subscribed?\norganization.payment_processor.subscription",
          "# Where a receipt goes: an owner, falling back to any member\norganization.billing_email"
        ]
      end

      def brief
        <<~BRIEF.strip
          ## Payments (sparrow_pay)

          A thin layer over the Pay gem, and thinner than you may expect. Pay
          owns the API calls, the webhooks and the subscription lifecycle.
          sparrow_pay decides who the customer is, and stops.

          Configuration in this app right now:
          - Processor: #{processor_line}

          What you get:
          - THE ORGANIZATION IS THE CUSTOMER, never the person. A person can
            belong to several organizations and can leave; a subscription
            attached to a person walks out of the door with them.
            `SparrowPay::Billable` is included into SparrowAuth::Organization by
            the engine, automatically. Do not include it yourself and never put
            it on an account model.
          - `organization.payment_processor` -- Pay's customer object. Everything
            about subscriptions, charges and payment methods is Pay's API from
            here, and is documented by Pay.
          - `organization.billing_email` -- where a receipt goes. Prefers a
            membership whose role is the literal string "owner", falling back to
            any member, so an organization mid-handover still has somewhere to
            send a failed-payment notice. That is the one place in SparrowKit
            where a role's value means anything.
          - Plans, prices and product names are configured at the processor, not
            in this codebase. Do not create a Plan model.

          What you DO NOT get, and should not write code expecting:
          - There is no `organization.billing` object. Ask Pay.
          - There are no billing status columns and no plan catalogue.
          - Nothing emits a billing notification. Subscribe to Pay's own hooks.
          - There are no billing pages. A billing page carries your plan names
            and your upgrade argument; write it.

          The processor's API keys live in Rails encrypted credentials under
          their own top-level key, which is where Pay reads them. This gem's own
          settings are under `sparrow_pay:`.
        BRIEF
      end

      private

      def processor_line
        return "NOT set -- nothing can be charged until one is chosen" if report.processor.nil?

        name = Processors.label_for(report.processor)
        missing = report.credentials.reject { |field| field[:set] }
        return "#{name} (keys are set)" if missing.empty?

        "#{name} (MISSING #{missing.map { |field| field[:name] }.join(", ")} -- calls will fail to authenticate)"
      end
    end
  end
end
