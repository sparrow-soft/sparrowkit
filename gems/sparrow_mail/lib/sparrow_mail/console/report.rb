# frozen_string_literal: true

module SparrowMail
  module Console
    # What the console panel says, worked out without a web stack anywhere near
    # it.
    #
    # Separate from the controller on purpose. This gem depends on `mail` alone
    # and its suite has no Rails in it, which is worth keeping: a delivery layer
    # that can only be tested inside a Rails application is a delivery layer
    # nobody tests in isolation. So the reasoning lives here in plain Ruby, and
    # the controller is a shell that hands the result to a template.
    #
    # It also puts the rule that governs this page somewhere it can be tested
    # directly: **no credential value is ever included in the output**. Not
    # truncated, not masked, not the first four characters. A key rendered on a
    # page is a key in a screenshot, a screen recording and a browser history,
    # and a key that has been photographed has to be rotated.
    #
    # Settings are therefore reported by name only — which is also the more
    # useful answer, because the question a developer has is "did my key get
    # picked up", and "set" answers it.
    class Report
      # Names that carry a secret. Matched loosely on purpose: a provider adding
      # `api_secret` next year should be caught by the rule that already exists,
      # not by somebody remembering to extend a list.
      #
      # A COPY of sparrow_ui's rule, and it had already drifted: this one had
      # `auth`, sparrow_ui's did not, and sparrow_ui's is the one that decides
      # what the panel prints. Two regexes for one decision disagreeing about
      # which values are safe to show is exactly the failure this constant
      # exists to prevent.
      #
      # It stays a constant here rather than delegating, because this gem is not
      # allowed to know sparrow_ui exists -- sparrow_ui is development-group and
      # this file is loaded in production. So the rule is copied deliberately,
      # and a spec holds the two in step rather than a comment asking somebody
      # to.
      SECRET_NAME = /key|secret|token|password|credential|auth_code|auth_token|authorization|user_name/i

      # The adapter this gem selects for ITSELF when a developer has not chosen
      # one -- see the railtie. Named here, and it is not the list of provider
      # names that Console::Adapters rightly refuses to keep: this is ours, and
      # the panel has to be able to say something true about a state we put the
      # application into without being asked.
      #
      # What it must say is that mail is going nowhere. Left alone, selecting an
      # adapter by default would flip this page from "no provider configured" to
      # a green "Sending through Preview" -- turning a fallback whose whole
      # purpose is to stop mail being lost silently into a page that claims mail
      # is being delivered.
      FALLBACK_ADAPTER = :preview

      # `configuration`, not `config`. The wrong name sat here unnoticed because
      # every spec passed a configuration in explicitly, so the default was
      # never once evaluated -- until the console hub called `Report.new` with
      # no arguments and the Mail card started reporting NoMethodError.
      def initialize(config = SparrowMail.configuration, registry: SparrowMail.registry)
        @config = config
        @registry = registry
      end

      attr_reader :config, :registry

      def findings
        [
          no_adapter,
          fallback_adapter,
          sandbox,
          no_default_from,
          adapter_missing_settings,
          *streams_without_credentials,
          undeclared_shared_identity,
          shared_identities
        ].compact
      end

      # One row per stream: where it goes, and which settings it has — by name.
      def streams
        config.streams.map do |stream|
          settings = config.adapter_settings_for(stream)

          {
            name: stream,
            adapter: config.adapter_for_stream(stream),
            inherits_adapter: config.adapter_for_stream(stream) == config.adapter,
            shared_identity: config.shared_identity?(stream),
            secrets: setting_names(settings, secret: true),
            plain: setting_names(settings, secret: false)
          }
        end
      end

      def summary
        {
          adapter: config.adapter,
          default_from: config.default_from,
          sandbox: config.sandbox?,
          available: registry.names.map(&:to_s).sort
        }
      end

      # The same findings, squeezed down to what fits on a card on the hub.
      #
      # Notes are dropped rather than counted. Sandbox and a declared shared
      # identity are both notes, both are correct in development, and a hub that
      # says "check this" about the state it expects you to be in teaches you to
      # ignore it -- which costs the badge its only job on the day it means
      # something.
      #
      # Returns a plain Hash, not a SparrowUi::Console::Status. This gem is not
      # allowed to know sparrow_ui exists: sparrow_ui is a development-group gem
      # and this file is loaded in production. The railtie does the translation,
      # inside the guard that already establishes the console is there.
      def status
        return {state: :unconfigured, detail: "No provider is configured, so no mail can leave."} if config.adapter.nil?

        if fallback?
          return {
            state: :unconfigured,
            detail: "No provider yet. Mail is being written to " \
                    "#{SparrowMail::Adapters::Preview::DIRECTORY} so you can read it."
          }
        end

        errors = findings.select { |f| f[:level] == :error }
        return {state: :attention, detail: errors.first[:title] + "."} if errors.any?

        warnings = findings.select { |f| f[:level] == :warning }
        return {state: :attention, detail: warnings.first[:title] + "."} if warnings.any?

        {state: :ready, detail: "Sending through #{registry.display_name_for(config.adapter)}."}
      end

      private

      def fallback?
        config.adapter&.to_sym == FALLBACK_ADAPTER
      end

      # Not an error, and not silence either.
      #
      # Nothing is broken -- this is the state a fresh application is meant to
      # be in, and mail is being kept rather than lost. But an application that
      # deployed like this would send nothing to anybody, so the page says so
      # every time it is looked at rather than once at install.
      def fallback_adapter
        return unless fallback?

        {
          level: :warning,
          title: "No provider is configured yet",
          detail: "Mail is being written to #{SparrowMail::Adapters::Preview::DIRECTORY} " \
                  "instead of sent, so nothing is lost while you build. Choose a provider " \
                  "above before you deploy: with this one, nobody receives anything."
        }
      end

      def no_adapter
        return if config.adapter

        {
          level: :error,
          title: "No provider is configured",
          detail: "SPARROW_MAIL_ADAPTER is unset and nothing set config.adapter, so " \
                  "mail cannot leave at all. Known providers: " \
                  "#{registry.names.map(&:to_s).sort.join(", ")}."
        }
      end

      def sandbox
        return unless config.sandbox?

        {
          level: :note,
          title: "Sandbox is on",
          detail: "Messages are handed to the provider marked as sandbox, so nothing " \
                  "reaches a real inbox. Right for development, and worth checking " \
                  "twice anywhere else."
        }
      end

      # The placeholder counts as no sender, because it is.
      #
      # Development gets SparrowMail::FALLBACK_FROM so that a fresh application
      # can send at all -- without it, mail had somewhere to go and no address to
      # come from, and the first sign-in raised. Treating that as "a sender is
      # configured" would swap one silent failure for a page saying everything
      # is fine while every message goes out from an address at
      # localhost.invalid.
      def fallback_from?
        config.default_from == SparrowMail::FALLBACK_FROM
      end

      def no_default_from
        return if config.default_from && !fallback_from?

        {
          level: :warning,
          title: "There is no default sender",
          detail: if fallback_from?
                    "Mail is going out from a placeholder address that can never " \
                    "receive a reply, so nothing is lost while you build. Set a real " \
                    "one above before you deploy."
                  else
                    "A message that does not set its own From has nothing to fall back " \
                    "on and will be refused. Set SPARROW_MAIL_DEFAULT_FROM or " \
                    "config.default_from."
                  end
        }
      end

      # The provider is chosen and is missing something it says it needs.
      #
      # Asked of the adapter rather than guessed at here: every adapter already
      # declares `required_settings` and refuses to build without them, so this
      # reports the same answer the first send would give -- before it gives it.
      #
      # It reported nothing at all until now. The transactional stream was
      # exempt from the credentials check on the reasoning that it inherits the
      # top-level settings, which it does; they were simply empty. So a provider
      # saved with a blank API key showed "Sending through Postmark" in green,
      # and the first thing a developer saw was the last thing that was true.
      def adapter_missing_settings
        return if config.adapter.nil?

        missing = missing_settings_for_adapter
        return if missing.empty?

        {
          level: :error,
          title: "#{config.adapter} is missing #{missing.join(", ")}",
          detail: "The provider is chosen but not finished. A message sent now " \
                  "would be refused before it left the application."
        }
      end

      def missing_settings_for_adapter
        klass = SparrowMail.registry.fetch(config.adapter)
        settings = config.adapter_settings_for(SparrowMail::Envelope::DEFAULT_STREAM)

        klass.required_settings.reject do |key|
          value = settings[key]
          !value.nil? && !value.to_s.strip.empty?
        end
      rescue
        # An adapter that cannot be looked up is somebody else's problem -- the
        # no_adapter finding covers the case that matters.
        []
      end

      # The trap this gem was reworked to prevent, reported before it bites.
      #
      # Credentials belong to the provider that issued them, so a stream naming a
      # different adapter starts from nothing and must say what it needs. A
      # stream that forgot has no secret in its settings at all and will fail to
      # authenticate the first time it sends — which for a broadcast stream might
      # be a month after it was configured.
      def streams_without_credentials
        config.streams.filter_map { |stream|
          next if stream == SparrowMail::Envelope::DEFAULT_STREAM
          next if config.adapter_for_stream(stream) == config.adapter
          next if has_secret?(config.adapter_settings_for(stream))

          {
            level: :error,
            title: "The #{stream} stream has no credentials of its own",
            detail: "It sends through #{config.adapter_for_stream(stream)} while the " \
                    "default provider is #{config.adapter}. Credentials are not " \
                    "inherited across providers — a key issued by one is meaningless " \
                    "to another — so this stream has none and will fail to " \
                    "authenticate when it first sends."
          }
        }
      end

      # Declared separate, actually sharing.
      #
      # This used to raise at boot, which meant a stream declared badly stopped
      # the application rather than the mail. Reported here instead, where it
      # can be read and acted on -- and where it does not make the simple case
      # harder than doing nothing.
      def undeclared_shared_identity
        sharing = SparrowMail.streams_sharing_identity
        return if sharing.empty?

        {
          level: :warning,
          title: "#{sharing.join(", ")} #{(sharing.size == 1) ? "shares" : "share"} the transactional sending identity",
          detail: "The stream is declared but not separated: it inherits the same " \
                  "credentials, so the provider keeps one reputation for both and a " \
                  "complaint about bulk mail counts against sign-in codes. Give it " \
                  "its own credentials, its own provider, or say shared_identity: " \
                  "true to accept it deliberately."
        }
      end

      # Not a fault, but the thing this gem exists to make deliberate.
      def shared_identities
        shared = config.streams.select { |stream| config.shared_identity?(stream) }
        return if shared.empty?

        {
          level: :note,
          title: "#{shared.join(", ")} #{(shared.size == 1) ? "shares" : "share"} the transactional identity",
          detail: "Declared deliberately with shared_identity. Spam complaints against " \
                  "this mail count against the reputation that carries sign-in codes, " \
                  "which is the thing streams exist to prevent."
        }
      end

      def has_secret?(settings)
        settings.keys.any? { |name| name.to_s.match?(SECRET_NAME) }
      end

      # Names only, never values. The one rule this page has.
      def setting_names(settings, secret:)
        settings.keys.map(&:to_s).select { |name| name.match?(SECRET_NAME) == secret }.sort
      end
    end
  end
end
