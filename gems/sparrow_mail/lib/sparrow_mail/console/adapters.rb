# frozen_string_literal: true

module SparrowMail
  module Console
    # Everything the control panel knows about the adapters, derived from the
    # registry and from the adapter classes themselves.
    #
    # THERE IS NO LIST OF PROVIDER NAMES IN THIS FILE, and there must never be
    # one. +SparrowMail.registry.names+ says which adapters exist and
    # +Adapters::Base.required_settings+ says what each one needs, so an adapter
    # added tomorrow -- ours, or an application's own registered with
    # +SparrowMail.register_adapter+ -- shows up on the panel with its own
    # fields and no edit here. The moment a provider name is typed out, the
    # panel starts drifting from the gem it configures, and the drift is
    # invisible: a form that quietly omits a required setting renders fine and
    # saves a configuration that cannot build an adapter.
    module Adapters
      # Whole words that read wrong title-cased. Deliberately about setting
      # NAMES rather than providers: `api_key` is a name we will keep seeing
      # from adapters nobody here has read.
      ACRONYMS = %w[api dns id ip smtp ssl tls uri url].freeze

      # One setting an adapter asks for, as the form renders it.
      #
      # Everything here beyond the name is the adapter's answer, passed
      # through: whether the setting is required, the values it may take, and
      # a sentence about what it is. The console adds nothing of its own, so a
      # provider's dropdown or hint changes when the adapter does and not when
      # somebody remembers to edit a view.
      class Field
        attr_reader :name, :choices, :hint

        def initialize(name, required: true, choices: nil, hint: nil)
          @name = name.to_sym
          @required = required
          @choices = choices
          @hint = hint
        end

        # False for a setting the adapter works without. The panel marks it
        # so, and the marker is what tells a developer they can stop.
        def required?
          @required
        end

        # True when the adapter listed the values this setting may take, in
        # which case the panel renders a dropdown rather than a text box.
        def choices?
          !choices.nil? && !choices.empty?
        end

        # :api_key -> "API key". Derived rather than looked up, because these
        # names come from adapters this gem has never seen.
        def label
          words = name.to_s.split("_").map { |word| ACRONYMS.include?(word) ? word.upcase : word }
          first, *rest = words
          [first.sub(/\A[a-z]/, &:upcase), *rest].join(" ")
        end

        # Asked of sparrow_ui rather than answered here.
        #
        # The console decides what a secret is by matching the field's NAME,
        # and it is the same decision that makes Settings.write drop a blank
        # one instead of erasing the stored value. Two copies of that rule
        # would drift, and the drift shows up as a key rendered on screen, or
        # as a saved form wiping the key it did not display. The panel only
        # ever runs with sparrow_ui mounted, so there is nothing to fall back
        # to and nothing worth guessing.
        def secret?
          ::SparrowUi::Console::Settings.secret?(name)
        end

        # There was an `input_type` here, answering "password" or "text", and
        # it is gone rather than corrected. A secret is now rendered by
        # sparrow_ui's own field partial, which is a `type="text"` box masked
        # in CSS -- because `type="password"` is exactly what makes a browser
        # offer to save an API key into the developer's password manager.
        #
        # Deleted because it would have gone on saying "password" while
        # nothing on the page was one, and the next person to want a field
        # would have believed it.
      end

      # One adapter as the panel offers it: its registry name, the fields it
      # requires, what the provider tells one sender from another by, and --
      # when its gem is missing -- why it cannot be chosen.
      class Choice
        attr_reader :name, :fields, :identity_fields, :unavailable_reason

        def initialize(name:, display_name: nil, fields: [], identity_fields: [],
          reputation_bearing: false, unavailable_reason: nil, provider: true)
          @name = name.to_sym
          @display_name = display_name
          @fields = fields
          @identity_fields = identity_fields
          @reputation_bearing = reputation_bearing
          @unavailable_reason = unavailable_reason
          @provider = provider
        end

        # Whether to offer it as a way of sending mail. True for an adapter
        # whose gem is missing, deliberately: Amazon SES that cannot be built
        # is still a provider, and listing it as unavailable with the reason is
        # more use than hiding it.
        def provider? = @provider

        # The brand, as the provider spells it. Asked of the adapter class --
        # see Adapters::Base.display_name -- so there is still no list of
        # provider names here.
        #
        # Falls back to the registry key for an adapter whose gem is missing:
        # the class cannot be loaded to ask it, and the key is the only honest
        # answer left.
        def display_name
          @display_name || name.to_s
        end

        def available?
          unavailable_reason.nil?
        end

        def settings?
          !fields.empty?
        end

        # Whether putting two kinds of mail through this provider puts anything
        # at risk. False for adapters that do not really send, which is why the
        # panel says nothing about separation when one of those is chosen for
        # both -- there is no reputation to keep apart.
        def reputation_bearing?
          @reputation_bearing
        end

        # What the panel names when it explains that two streams would share a
        # sending identity. Taken from the adapter, because which settings
        # constitute an identity is the adapter's answer: Mailgun's is the key
        # and the sending domain, SMTP's is the relay and the login.
        def identity_labels
          identity_fields.map(&:label)
        end
      end

      module_function

      # Adapters a person could reasonably choose on this page, in the
      # registry's order.
      #
      # Derived from the registry -- there is no list of provider names here and
      # there must never be one. What is filtered out is every adapter that
      # hands mail to nobody: :test records in memory, :preview writes to a
      # folder while no provider has been chosen. Each says so itself, through
      # Adapters::Base.provider?, so one added tomorrow answers for itself.
      #
      # This was a hardcoded `%i[test]` and it was already wrong by the time
      # :preview existed -- which is the whole argument against the list this
      # file's own comment says must never appear.
      #
      # Offering them was a real defect: the panel's "send a test email" button
      # could answer "handed to test" having reached no network at all, so the
      # one control whose entire purpose is answering "do my credentials work?"
      # reported success without them.
      #
      # `find` still resolves both, so an application that selects one
      # deliberately in an initializer or in the test environment is unaffected.
      def all
        SparrowMail.registry.names.map { |name| describe(name) }.select(&:provider?)
      end

      # The named adapter, or nil when nothing is registered under that name.
      # Nil rather than an exception: an unknown adapter arrives as a form
      # parameter, and a parameter the panel does not recognise is a 422, not a
      # 500.
      # Coerced through a String on the way in. What arrives here is a form
      # parameter, so it may be any shape at all -- an array, a nested hash --
      # and Registry#key? calls to_sym on whatever it is handed.
      def find(name)
        key = name.to_s
        return nil if key.empty?
        return nil unless SparrowMail.registry.key?(key)

        describe(key)
      end

      # Registry#fetch is lazy: it requires the adapter's file on first use and
      # raises ConfigurationError when the gem behind it is not installed --
      # Amazon SES needs the AWS SDK, which an application sending through
      # Postmark has no reason to carry. That is a fact to show the developer,
      # not a reason for the page to fall over, so the adapter is listed as
      # unavailable with the provider's own explanation of what is missing.
      def describe(name)
        name = name.to_sym
        klass = SparrowMail.registry.fetch(name)

        Choice.new(
          name: name,
          display_name: klass.display_name,
          fields: fields_for(klass),
          identity_fields: klass.identity_settings.map { |setting| Field.new(setting) },
          reputation_bearing: klass.reputation_bearing?,
          provider: klass.provider?
        )
      rescue SparrowMail::ConfigurationError => e
        # The class never defined, so it cannot be asked how it spells itself.
        # The registry keeps a fallback for exactly this: an adapter listed as
        # `ses` when it means Amazon SES reads like something is broken.
        Choice.new(
          name: name,
          display_name: SparrowMail.registry.display_name_for(name),
          unavailable_reason: e.message
        )
      end

      # Every setting the adapter asks for, required ones first and then the
      # ones it works without, each carrying what the adapter says about it.
      def fields_for(klass)
        required = klass.required_settings.map { |setting| field_for(klass, setting, required: true) }
        optional = klass.optional_settings.map { |setting| field_for(klass, setting, required: false) }
        required + optional
      end

      def field_for(klass, setting, required:)
        Field.new(
          setting,
          required: required,
          choices: klass.setting_choices(setting),
          hint: klass.setting_hint(setting)
        )
      end
    end
  end
end
