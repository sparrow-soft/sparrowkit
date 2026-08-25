# frozen_string_literal: true

module SparrowMail
  # Which adapter to use and how to talk to it.
  #
  # Everything here can come from the environment, which is the point: changing
  # email provider in a deployed application is a change to
  # SPARROW_MAIL_ADAPTER and a couple of credentials, not a code change.
  # Values set in code win over the environment, because an initializer is the
  # more specific statement of intent.
  class Configuration
    ADAPTER_ENV = "SPARROW_MAIL_ADAPTER"
    SANDBOX_ENV = "SPARROW_MAIL_SANDBOX"
    DEFAULT_FROM_ENV = "SPARROW_MAIL_DEFAULT_FROM"

    attr_writer :adapter, :sandbox, :default_from
    attr_accessor :settings, :logger

    def initialize(env = ENV)
      @env = env
      @adapter = nil
      @sandbox = nil
      @default_from = nil
      @settings = {}
      @logger = nil
      @stream_overrides = {}
    end

    # Declares a stream and how mail on it should leave.
    #
    #   config.stream :broadcast, settings: {message_stream: "broadcast"}
    #   config.stream :broadcast, adapter: :mailgun,
    #                             settings: {domain: "news.example.com"}
    #
    # Bulk mail and transactional mail must not share a sending reputation:
    # spam complaints against a newsletter damage the deliverability of sign-in
    # codes sent from the same identity, and some providers suspend accounts
    # over it.
    #
    # Providers that model this themselves take the first form, where only a
    # provider-specific setting changes. Providers that do not take the second,
    # where the separation comes from a different adapter, a different account,
    # or a different sending domain. Both produce real separation; only the
    # mechanism differs.
    # `shared_identity: true` says the application knows this stream sends
    # through the same identity as the transactional one and wants the label
    # anyway. Without it, a stream that cannot actually be separated is refused
    # rather than quietly providing none.
    def stream(name, adapter: nil, settings: {}, shared_identity: false)
      @stream_overrides[name.to_sym] = {
        adapter: adapter&.to_sym,
        settings: symbolize(settings),
        shared_identity: shared_identity
      }
      self
    end

    def shared_identity?(name)
      !!@stream_overrides.dig(name.to_sym, :shared_identity)
    end

    # Every stream that can be sent on. Transactional always exists; it is what
    # a message with no stream header uses.
    def streams
      ([Envelope::DEFAULT_STREAM] + @stream_overrides.keys).uniq
    end

    def stream?(name)
      streams.include?(name.to_sym)
    end

    def adapter_for_stream(name)
      @stream_overrides.dig(name.to_sym, :adapter) || adapter
    end

    # What one stream's adapter is built with.
    #
    # Credentials belong to the provider that issued them and are inherited only
    # by a stream sending through that same provider. A stream that names a
    # different adapter starts from nothing and must say what it needs.
    #
    # The alternative — merging everything into everything — means a Postmark
    # token reaching a SendLayer adapter, and a stream that forgot to declare
    # its own key silently authenticating as something else instead of failing.
    # Credentials that can be inherited across providers are credentials that
    # can be confused, and one that is confused quietly is worse than one that
    # is missing loudly.
    #
    # sandbox and default_from are not credentials. They describe the message
    # and the run rather than the account, so they reach every stream.
    def adapter_settings_for(name)
      overrides = @stream_overrides[name.to_sym] || {}

      general_settings.merge(credentials_for(overrides)).merge(overrides[:settings] || {})
    end

    # Used when a message has no From of its own. Applications almost always
    # send from one address, and repeating it in every mailer is how it ends up
    # stale in three of them.
    def default_from
      value = @default_from || @env[DEFAULT_FROM_ENV]
      return nil if value.nil? || value.to_s.empty?

      with_product_name(value.to_s)
    end

    # A bare address gets the product's name in front of it, so mail arrives
    # from "Acme Corp <no-reply@acme.test>" rather than from an address on its
    # own, which reads like a machine and lands worse.
    #
    # A mailbox that already names a sender is left exactly as it is: that name
    # IS the override, the same way a stored passkey domain is. There is no
    # separate flag, because a flag and a value can disagree and then something
    # has to decide which one lied.
    def with_product_name(mailbox)
      return mailbox if mailbox.include?("<")

      name = SparrowMail.application_name.to_s.strip
      return mailbox if name.empty?

      # RFC 5322 specials. Left unquoted, `Acme, Inc <a@b>` is a
      # comma-separated list of two addresses and the mail goes to a recipient
      # called "Acme".
      name = %("#{name.delete('"')}") if name.match?(/[(),.:;<>@\[\]\\"]/)

      "#{name} <#{mailbox}>"
    end

    def adapter
      value = @adapter || @env[ADAPTER_ENV]
      (value.nil? || value.to_s.empty?) ? nil : value.to_sym
    end

    def sandbox?
      return truthy?(@sandbox) unless @sandbox.nil?

      truthy?(@env[SANDBOX_ENV])
    end

    # What actually gets handed to the adapter's constructor. Sandbox is folded
    # in here so an adapter has exactly one place to read it from, whether it
    # was built by this gem or by hand.
    def adapter_settings
      general_settings.merge(symbolize(settings))
    end

    # Everything that is about the message or the run rather than about an
    # account with a provider. Safe to hand to any adapter, because none of it
    # identifies a sender to anybody.
    def general_settings
      {sandbox: sandbox?, default_from: default_from}.compact
    end

    # The default provider's credentials, offered to a stream only when that
    # stream sends through the same provider. A stream that named its own
    # adapter gets none of them.
    def credentials_for(overrides)
      stream_adapter = overrides[:adapter]
      return {} unless stream_adapter.nil? || stream_adapter == adapter

      symbolize(settings)
    end

    # Settings hold API keys. Anything that prints a Configuration — an error
    # reporter, a console, a `pp` in a debugging session — must not print those.
    def inspect
      "#<SparrowMail::Configuration adapter=#{adapter.inspect} " \
        "sandbox=#{sandbox?} settings=#{symbolize(settings).keys.inspect} " \
        "streams=#{streams.inspect} " \
        "logger=#{logger ? logger.class.name : "nil"}>"
    end
    alias_method :to_s, :inspect

    private

    def symbolize(hash)
      (hash || {}).to_h { |key, value| [key.to_sym, value] }
    end

    def truthy?(value)
      return false if value.nil?
      return value if [true, false].include?(value)

      %w[1 true yes on].include?(value.to_s.strip.downcase)
    end
  end
end
