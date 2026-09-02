# frozen_string_literal: true

require "mail"

require_relative "sparrow_mail/version"
require_relative "sparrow_mail/errors"
require_relative "sparrow_mail/redactor"
require_relative "sparrow_mail/envelope"
require_relative "sparrow_mail/result"
require_relative "sparrow_mail/configuration"
require_relative "sparrow_mail/registry"
require_relative "sparrow_mail/adapters/preview"
require_relative "sparrow_mail/console/report"
require_relative "sparrow_mail/adapters/base"
require_relative "sparrow_mail/delivery_method"

# Provider-agnostic email delivery.
#
# Two rules are enforced by this gem's core rather than left to each adapter,
# because both were learned the expensive way and neither survives being a
# convention:
#
#   1. Message bodies are never logged. Transactional mail carries live sign-in
#      codes and invitation tokens. A log aggregator is a place those outlive
#      their expiry, in a system with a different access-control model than the
#      application that issued them.
#   2. A send is never retried. A timed-out send may well have been delivered;
#      retrying it puts a second copy of a one-time code in someone's inbox and
#      invalidates the first.
#
# Both live in SparrowMail::Adapters::Base. See the gem README for the
# reasoning at length, and spec/sparrow_mail/inviolable_rules_spec.rb for the
# structural checks that keep them true.
#
#   SparrowMail.configure do |config|
#     config.adapter  = :postmark
#     config.settings = {api_key: ENV["POSTMARK_API_KEY"]}
#     config.logger   = Rails.logger
#   end
#
#   SparrowMail.deliver!(mail)
module SparrowMail
  # Order matters: it is the order a developer is offered them in, and
  # Registry#names hands it over unsorted. The hosted providers come first,
  # then SMTP, which is whatever relay you already have, and last the two that
  # are not providers at all: Test never leaves the process, and Preview writes
  # to a folder while nobody has chosen a provider yet. Neither is offered on
  # the panel -- see Console::Adapters, which works that out by asking rather
  # than from a list.
  BUILT_IN_ADAPTERS = {
    postmark: ["sparrow_mail/adapters/postmark", "SparrowMail::Adapters::Postmark", "Postmark"],
    sendgrid: ["sparrow_mail/adapters/sendgrid", "SparrowMail::Adapters::SendGrid", "SendGrid"],
    sendlayer: ["sparrow_mail/adapters/send_layer", "SparrowMail::Adapters::SendLayer", "SendLayer"],
    mailgun: ["sparrow_mail/adapters/mailgun", "SparrowMail::Adapters::Mailgun", "Mailgun"],
    ses: ["sparrow_mail/adapters/ses", "SparrowMail::Adapters::SES", "Amazon SES"],
    smtp: ["sparrow_mail/adapters/smtp", "SparrowMail::Adapters::SMTP", "SMTP"],
    test: ["sparrow_mail/adapters/test", "SparrowMail::Adapters::Test", "Test"],
    preview: ["sparrow_mail/adapters/preview", "SparrowMail::Adapters::Preview", "Preview"]
  }.freeze

  # The sender a development application gets when nobody has set one.
  #
  # `.invalid` is reserved by RFC 2606 and can never be registered, so nothing
  # can reply to it and no bounce reaches anybody. Named here rather than
  # written twice: the railtie sets it and the console has to recognise it, and
  # a panel that reported a placeholder as a configured sender would be lying in
  # exactly the way the preview adapter was stopped from lying.
  FALLBACK_FROM = "SparrowKit (no sender set) <no-reply@localhost.invalid>"

  # The top-level key this gem reads in the host's Rails credentials, named
  # after the gem so that a developer looking at `credentials:edit` can see
  # whose settings those are without being told.
  #
  # Module level, NOT inside `class << self`. A constant defined in there
  # belongs to the singleton class, so `SparrowMail::CREDENTIALS_KEY` does not
  # resolve -- which is how this was first written, and the console panel
  # referring to it failed to load with an uninitialized constant.
  CREDENTIALS_KEY = :sparrow_mail

  # Where the product's own name is kept, which is NOT this gem's key.
  #
  # `sparrowkit: app_name:` is a fact about the product rather than about mail:
  # the passkey prompt shows it, and so does the From line. Asking for it on
  # every panel that needs it is asking for two answers, and the day they
  # disagree neither page looks wrong.
  #
  # Read, never written. The control panel writes it; this only inherits it.
  SHARED_KEY = :sparrowkit

  # The stream whose adapter is the default one. Every other key under
  # `sparrow_mail:` holding a Hash is a stream in its own right.
  CREDENTIALS_DEFAULT_STREAM = :transactional

  # Keys at that level that are settings rather than streams.
  CREDENTIALS_SCALARS = [:default_from, :sandbox].freeze

  # Stream keys the control panel used to write, and what they mean now.
  #
  # Before 1.3.0 the panel stored the second provider under `marketing:`,
  # while this README, the Postmark adapter and the conformance suite all
  # called that stream `broadcast` -- so a developer who configured two
  # providers on the panel and then set the header the README showed them
  # got "unknown stream :broadcast" from the fail-closed lookup below. The
  # panel now writes `broadcast:` and rewrites an old key on its next save;
  # this is what keeps mail sending, as broadcast, in between.
  CREDENTIALS_STREAM_ALIASES = {marketing: :broadcast}.freeze

  class << self
    def configuration
      @configuration ||= Configuration.new
    end

    def configure
      yield(configuration) if block_given?
      @adapters = nil
      configuration
    end

    # The adapter for the transactional stream, which is what mail with no
    # stream of its own uses.
    def adapter
      adapter_for(Envelope::DEFAULT_STREAM)
    end

    # The adapter for one stream, memoised per stream for the process.
    # Reconfiguring discards them all.
    def adapter_for(stream)
      adapters[stream.to_sym] ||= build_adapter(stream.to_sym)
    end

    def registry
      @registry ||= default_registry
    end

    # What the product is called, as the control panel's front page recorded it.
    # Empty when nobody has said.
    #
    # Deliberately not logged on failure, for the reason given below.
    def application_name
      return "" unless defined?(::Rails) && ::Rails.respond_to?(:application)

      ::Rails.application&.credentials&.config&.dig(SHARED_KEY, :app_name).to_s
    rescue
      ""
    end

    # What is stored in `sparrow_mail:`, or {} -- for a host with no
    # credentials, no master key, or nothing written yet, all of which are
    # ordinary states rather than errors.
    def credentials
      return {} unless defined?(::Rails) && ::Rails.respond_to?(:application)

      value = ::Rails.application&.credentials&.config&.dig(CREDENTIALS_KEY)
      value.is_a?(Hash) ? value : {}
    rescue
      # An unreadable credentials file must not stop an application booting: it
      # is the same situation as not having one, and the defaults exist for it.
      #
      # NOT logged, and that is deliberate rather than an oversight. This gem's
      # first inviolable rule is that logging happens in exactly one file --
      # see spec/sparrow_mail/inviolable_rules_spec.rb -- so that no code path
      # near a message can put a body in a log. A warning here would have been
      # perfectly harmless and would also have been the first exception, which
      # is how that rule stops being a rule. Rails already complains loudly
      # about credentials it cannot decrypt.
      {}
    end

    # Re-reads credentials into the configuration this process is running on.
    #
    # The console panel writes credentials and nothing else. Without this the
    # process that wrote them keeps using the configuration it built at boot:
    # the panel says "saved", the hub badge goes on saying "not set up", and
    # mail keeps leaving through the provider you just replaced -- all of it
    # until somebody restarts the server, and nothing on the page says so.
    #
    # `replace: true` is the difference from boot. Coming back to this panel to
    # switch provider is the ordinary case, and merging would leave the old
    # provider's keys sitting underneath the new one's.
    def reload_credentials!
      apply_credentials!(credentials, replace: true)
    end

    # Applies them over the defaults. Called from the railtie before the host's
    # own initializers, so anything set in config/initializers wins.
    #
    # `replace` decides what happens to the default stream's existing settings.
    # At boot it cannot matter -- a fresh Configuration has none -- so it
    # defaults to the merge that has always happened, and only the reload above
    # asks for anything else.
    def apply_credentials!(stored = credentials, replace: false)
      return configuration if stored.empty?

      configure do |config|
        config.default_from = stored[:default_from] if stored[:default_from]
        config.sandbox = stored[:sandbox] unless stored[:sandbox].nil?

        stored.each do |name, value|
          next unless value.is_a?(Hash)
          next if CREDENTIALS_SCALARS.include?(name.to_sym)

          # An old key is read under its current name, unless the current
          # name is stored as well, in which case the old one is stale and
          # the panel's next save will remove it.
          if CREDENTIALS_STREAM_ALIASES.key?(name.to_sym)
            next if stored.key?(CREDENTIALS_STREAM_ALIASES[name.to_sym])
            name = CREDENTIALS_STREAM_ALIASES[name.to_sym]
          end

          adapter = value[:adapter]
          settings = value.except(:adapter)

          if name.to_sym == CREDENTIALS_DEFAULT_STREAM
            # The default adapter, which is what mail naming no stream uses.
            config.adapter = adapter if adapter
            fresh = symbolize_settings(settings)
            config.settings = replace ? fresh : config.settings.merge(fresh)
          else
            # A stream, declared exactly as an initializer would declare it.
            # `shared_identity` is passed through so a deliberate overlap
            # stays deliberate rather than being refused on boot.
            config.stream(
              name.to_sym,
              adapter: adapter,
              settings: symbolize_settings(settings.except(:shared_identity)),
              shared_identity: !!settings[:shared_identity]
            )
          end
        end
      end
    end

    # Registers a third-party adapter. It must subclass
    # SparrowMail::Adapters::Base and should pass the conformance suite —
    # see the README, "Writing an adapter".
    def register_adapter(name, klass)
      registry.register(name, klass)
    end

    # Credentials come back with symbol keys already, but a hand-edited file
    # can produce either, and an adapter looking up :api_key does not find
    # "api_key". Cheap insurance on a path that runs once at boot.
    def symbolize_settings(settings)
      settings.to_h { |name, value| [name.to_sym, value] }
    end

    # Delivers, raising SparrowMail::DeliveryError on failure. This is what
    # ActionMailer's delivery method calls. Routed to the adapter for whichever
    # stream the message names.
    def deliver!(message)
      adapter_for(Envelope.stream_from(message)).deliver!(message)
    end

    # Delivers, returning a Result that carries the failure rather than raising
    # it. See SparrowMail::Adapters::Base#deliver.
    def deliver(message)
      adapter_for(Envelope.stream_from(message)).deliver(message)
    end

    # Messages held back in sandbox mode, and everything the test adapter
    # receives. Grows only in those two cases; a production adapter outside
    # sandbox mode records nothing.
    def deliveries
      @deliveries ||= []
    end

    def record_delivery(envelope)
      deliveries << envelope
    end

    # One message, read back, whichever store it landed in.
    Readback = Struct.new(:to, :subject, :text)

    # What this application has sent and can still read.
    #
    # Two adapters record instead of sending -- :test keeps envelopes in memory,
    # :preview writes .eml files -- and two callers want to read a sign-in code
    # back out: the test helpers sparrow_auth ships, and the console's sign-in
    # harness. Neither should have to know which store is live, and both got it
    # wrong when they did. The test helpers read ActionMailer's deliveries for a
    # release, which is empty in every application that installs the way we tell
    # people to.
    #
    # Newest first, and never a delivery that actually went to a provider: a
    # real send leaves nothing here to read, which is the correct answer rather
    # than a gap.
    def readable_deliveries(limit: 25)
      from_memory = deliveries.reverse.first(limit).map do |envelope|
        Readback.new(
          to: envelope.all_recipients.map(&:email),
          subject: envelope.subject.to_s,
          text: envelope.text_body.to_s
        )
      end
      return from_memory if from_memory.any?

      Adapters::Preview.recent(limit: limit).map do |message|
        Readback.new(
          to: message.to.split(",").map(&:strip),
          subject: message.subject,
          text: message.text
        )
      end
    end

    # Drops configuration, the memoised adapter and recorded deliveries. For
    # test suites.
    def reset!
      @configuration = nil
      @adapters = nil
      @registry = nil
      @deliveries = nil
    end

    # Streams that are declared separate and are not.
    #
    # Declaring a stream is not the same as separating it: on a provider with no
    # stream concept of its own, a stream inheriting the same credentials sends
    # through the same identity, and the provider keeps one reputation for both.
    # The label is real and the protection is not, which reads as done.
    #
    # Reported rather than refused. Raising meant an application naming two
    # streams on one provider would not boot, so the gem whose job is "pick a
    # provider and send" made the simple case harder than doing nothing -- and
    # the way out was to stop declaring the second stream, which is worse than
    # declaring it badly. The control panel carries it instead.
    def streams_sharing_identity
      default = Envelope::DEFAULT_STREAM
      transactional = adapter_for(default)

      configuration.streams.select do |stream|
        next false if stream == default
        next false if configuration.shared_identity?(stream)

        adapter = adapter_for(stream)
        next false unless adapter.class.reputation_bearing?
        next false unless transactional.instance_of?(adapter.class)

        transactional.sending_identity(default) == adapter.sending_identity(stream)
      end
    rescue ConfigurationError
      # Nothing to say about a configuration that cannot build an adapter at
      # all. The panel reports that separately, and more usefully.
      []
    end

    private

    def adapters
      @adapters ||= {}
    end

    def build_adapter(stream)
      # Fail closed. A typo in a stream header would otherwise send bulk mail
      # down the transactional stream, which is the exact outcome streams exist
      # to prevent, and it would stay invisible until the reputation damage was
      # already done.
      unless configuration.stream?(stream)
        raise ConfigurationError,
          "unknown stream #{stream.inspect}. " \
          "Configured streams: #{configuration.streams.join(", ")}. " \
          "Declare it with SparrowMail.configure { |c| c.stream #{stream.inspect}, settings: {...} }."
      end

      name = configuration.adapter_for_stream(stream)

      if name.nil?
        raise ConfigurationError,
          "no adapter configured. Set SparrowMail.configure { |c| c.adapter = :postmark } " \
          "or the #{Configuration::ADAPTER_ENV} environment variable. " \
          "Available adapters: #{registry.names.join(", ")}."
      end

      registry.fetch(name).new(configuration.adapter_settings_for(stream))
    end

    def separation_message(stream, adapter)
      <<~MESSAGE.tr("\n", " ").squeeze(" ").strip + "\n\n" + separation_remedies(stream)
        stream #{stream.inspect} uses the same sending identity as
        #{Envelope::DEFAULT_STREAM.inspect} on the #{adapter.class.adapter_name} adapter
        (#{adapter.class.identity_settings.join(", ")}), so the provider cannot tell
        them apart and keeps one reputation for both. Bulk complaints would then
        decide whether transactional mail is delivered.
      MESSAGE
    end

    def separation_remedies(stream)
      <<~MESSAGE
        Give the stream its own identity:
          config.stream #{stream.inspect}, settings: {api_key: ENV["..."]}
        or send it through a different provider:
          config.stream #{stream.inspect}, adapter: :mailgun, settings: {...}
        or, if you want the label without the separation, say so:
          config.stream #{stream.inspect}, settings: {}, shared_identity: true
      MESSAGE
    end

    def default_registry
      Registry.new.tap do |registry|
        BUILT_IN_ADAPTERS.each do |name, (path, constant, display)|
          registry.register_lazy(name, path, constant, display)
        end
      end
    end
  end
end

# A Rails application loads Rails before Bundler.require, so this is always true
# there. It is deliberately a check rather than an attempt to load railties:
# requiring "rails/railtie" directly fails without ActiveSupport's core
# extensions already in place, and requiring "rails" would drag the whole
# framework into applications that do not have one, which is the opposite of why
# this gem depends on `mail` alone.
#
# The one case this misses is a plain Ruby script that requires sparrow_mail and
# then boots Rails by hand. If you are doing that, either load Rails first or
# require "sparrow_mail/railtie" yourself once it is up.
require_relative "sparrow_mail/railtie" if defined?(Rails::Railtie)
