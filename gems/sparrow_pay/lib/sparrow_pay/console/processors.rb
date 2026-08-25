# frozen_string_literal: true

module SparrowPay
  module Console
    # Which processors the console offers, and what each one needs entered.
    #
    # THERE IS NO LIST OF PROCESSOR NAMES IN THIS FILE, and there must never be
    # one. Both halves are asked of Pay:
    #
    #   which processors      Pay.enabled_processors
    #   what each one needs   the zero-argument readers on Pay's module for it
    #
    # That second one is worth explaining, because it looks like a trick and is
    # not. Every value Pay looks up in credentials is exposed as a reader taking
    # no arguments -- `Pay::<Processor>.private_key` and so on -- and those
    # readers are the whole set: Pay's own `find_value_by_name` is called from
    # nowhere else. So the readers ARE the field list, kept in step by whoever
    # is upgrading Pay rather than by whoever remembers this file exists.
    #
    # The alternative was a table of processors and their fields, which is the
    # thing the processor seam spec exists to refuse -- see
    # spec/sparrow_pay/processor_seam_spec.rb. A table would have been correct
    # on the day it was written and wrong at Pay's next release, and nothing
    # would have said so: the panel would quietly stop offering a field, the
    # developer would never enter it, and the failure would arrive as a webhook
    # that does not verify.
    module Processors
      # Pay's engine interface, which every processor module carries and none of
      # which is a credential. Named here because they are Pay's method names,
      # not any processor's -- adding to this list can never encode which
      # processor anybody is using.
      NOT_CREDENTIALS = %i[setup configure_webhooks model_names client].freeze

      # What a field is for, and whether it can be left blank.
      #
      # Keyed on the FIELD name, never on a processor's. That is what keeps it
      # inside the rule the rest of this file is built around: a processor Pay
      # adds tomorrow gets whatever entries it shares, and a field nobody has
      # written an entry for renders with no note rather than a wrong one. The
      # table it is NOT is the one this gem refuses -- processors and their
      # fields -- because that one goes stale silently at Pay's next release.
      #
      # The wording names no processor either, and that is not squeamishness:
      # spec/sparrow_pay/processor_seam_spec.rb greps this file for one. It is
      # also more accurate, since these names are shared -- a signing secret is
      # a signing secret wherever the webhook came from.
      #
      # `optional` is what a developer most needs and the panel could not
      # otherwise know. Pay exposes every credential as a reader with no way to
      # ask which are required, so without this the page shows five identical
      # boxes and a developer fills in five, hunting for two that do not exist
      # for their account.
      FIELD_GUIDANCE = {
        context: {
          optional: true,
          help: "Only for an organisation-level key -- one issued to a business " \
                "account that acts on several others. An ordinary account key " \
                "ignores this entirely, so leave it blank unless you know you " \
                "were given one."
        },
        webhook_receive_test_events: {
          optional: true,
          boolean: true,
          label: "Receive test webhook events",
          help: "Off means this application acts only on real events and " \
                "ignores anything from your processor's test mode -- which is " \
                "what you want in production, where a test event should never " \
                "move a subscription. On while you are wiring it up."
        },
        signing_secret: {
          help: "From the webhook endpoint you created at your processor, not " \
                "from the API keys page. It is what proves an incoming webhook " \
                "came from them rather than from anybody who found the URL."
        },
        public_key: {
          help: "The one that is safe in a browser. It goes in the page that " \
                "collects a card."
        },
        private_key: {
          help: "The secret half. It never leaves your server."
        }
      }.freeze

      module_function

      # Blank is a legitimate answer for this field.
      #
      # False for anything with no entry, which is the safe way round: an
      # unknown field is presented as needed, and the worst case is a developer
      # filling in something they did not have to.
      def optional?(name)
        !!FIELD_GUIDANCE.dig(name.to_sym, :optional)
      end

      # A sentence about this field, or nil for one nobody has written.
      def help_for(name)
        FIELD_GUIDANCE.dig(name.to_sym, :help)
      end

      # This field is on or off, so the panel draws a checkbox.
      #
      # Pay exposes no types -- every credential is a reader returning whatever
      # was stored -- so a field that is really a switch arrives as a text box
      # asking a developer to type the word "false". There is no way to derive
      # this; naming the few that are switches is the smallest thing that can
      # be wrong, and a field missing from the table is a text box, which is
      # what it would have been anyway.
      def boolean?(name)
        !!FIELD_GUIDANCE.dig(name.to_sym, :boolean)
      end

      # A processor's name as a person would write it: :paddle_billing ->
      # "Paddle Billing". An entry in the table wins, for the fields whose
      # derived name is technically right and reads like a log line.
      def label_for(name)
        FIELD_GUIDANCE.dig(name.to_sym, :label) ||
          name.to_s.split("_").map(&:capitalize).join(" ")
      end

      # Every processor Pay is willing to run, in Pay's own order.
      #
      # Not filtered by `enabled?`, deliberately. A processor is only "enabled"
      # once its client library is loaded AND its keys are present, so filtering
      # would hide every processor the developer has not set up yet -- which on
      # this page is all of them, and is the reason they came.
      def names
        return [] unless defined?(::Pay)

        ::Pay.enabled_processors.map(&:to_sym)
      end

      def known?(name)
        names.include?(name.to_s.to_sym)
      end

      # The credentials Pay reads for this processor, in a stable order.
      #
      # Empty for a processor whose module is not loaded, which is not an error:
      # Pay ships support for processors whose client gems a host has not
      # installed, and the panel says so rather than pretending there is nothing
      # to enter.
      def fields_for(name)
        mod = module_for(name)
        return [] if mod.nil?

        mod.singleton_methods(false)
          .reject { |method| NOT_CREDENTIALS.include?(method) }
          .reject { |method| method.to_s.end_with?("?", "=") }
          # Anything taking an argument is doing work, not reading a setting.
          # `parameters`, not `arity`, because a method whose only argument is a
          # required keyword reports an arity of 0 and would otherwise arrive
          # here as a text box that saves nothing.
          .select { |method| mod.method(method).parameters.empty? }
          # Required first, optional after, alphabetical inside each.
          #
          # Alphabetical alone put `context` at the top of the card -- the
          # field almost nobody needs, above the two they came for. Sorting on
          # `optional?` is a rule rather than a running order somebody has to
          # keep in step with Pay: a field Pay adds tomorrow lands among the
          # required ones, which is the safe half to be wrong about.
          .sort_by { |method| [optional?(method) ? 1 : 0, method.to_s] }
      end

      # Pay's module for a processor: :paddle_billing -> Pay::PaddleBilling.
      #
      # Derived from the key rather than looked up in a table, for the same
      # reason as everything else here.
      def module_for(name)
        return nil unless defined?(::Pay)
        return nil unless known?(name)

        constant = name.to_s.split("_").map(&:capitalize).join
        return nil unless ::Pay.const_defined?(constant, false)

        ::Pay.const_get(constant, false)
      rescue NameError
        nil
      end
    end
  end
end
