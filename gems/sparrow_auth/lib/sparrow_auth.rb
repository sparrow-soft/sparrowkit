# frozen_string_literal: true

require "uri"

require_relative "sparrow_auth/version"
require_relative "sparrow_auth/configuration"
require_relative "sparrow_auth/errors"
require_relative "sparrow_auth/seed"
require_relative "sparrow_auth/webauthn"
require_relative "sparrow_auth/tenanted" if defined?(ActiveSupport::Concern)
require_relative "sparrow_auth/engine" if defined?(Rails::Engine)

# Authentication for SparrowKit applications, as a mountable Rails engine on
# Rodauth.
#
# Rodauth owns the crypto, the ceremony handling and the flow security. This gem
# is configuration, the organization model, roles and glue,
# and deliberately reimplements none of it.
#
# One rule is not configurable, here or anywhere downstream: an email address is
# not trusted until it has been verified. Everything that grants access checks
# that, because an unverified address is only a claim, and treating a claim as
# an identity is how an invitation to one person becomes access for another.
module SparrowAuth
  # The top-level key this gem reads in the host's Rails credentials, named
  # after the gem so that a developer looking at `credentials:edit` can see
  # whose settings those are without being told.
  #
  # Module level, NOT inside `class << self`. A constant defined in there
  # belongs to the singleton class, so `SparrowAuth::CREDENTIALS_KEY` does not
  # resolve from anywhere else.
  CREDENTIALS_KEY = :sparrow_auth

  # Where the application's own address is kept, which is NOT this gem's key.
  #
  # `sparrowkit: app_url:` is a fact about the product as a whole rather than
  # about authentication — the mail links point at it, the control panel's front
  # page asks for it once, and a passkey binds to its domain. Keeping it here
  # would mean asking for the same address on every panel that needs it, which
  # is how two of them end up disagreeing.
  #
  # Read, never written. The control panel writes it; this only inherits it.
  SHARED_KEY = :sparrowkit

  class << self
    def config
      @config ||= Configuration.new
    end

    def configure
      yield(config) if block_given?
      config
    end

    def reset!
      @config = nil
    end

    # What is stored there, or {} -- for a host with no credentials, no master
    # key, or nothing written yet, all of which are ordinary states rather than
    # errors. A missing key is why the defaults exist.
    def credentials
      return {} unless defined?(::Rails) && ::Rails.respond_to?(:application)

      value = ::Rails.application&.credentials&.config&.dig(CREDENTIALS_KEY)
      value.is_a?(Hash) ? value : {}
    rescue => e
      # An unreadable credentials file must not stop an application booting.
      # It is the same failure as not having one, and Rails already says so
      # loudly elsewhere.
      ::Rails.logger&.warn("[sparrow_auth] could not read credentials: #{e.class}")
      {}
    end

    # The address the application is served at, as the control panel's front
    # page recorded it. Empty when nobody has said.
    def application_url
      return "" unless defined?(::Rails) && ::Rails.respond_to?(:application)

      ::Rails.application&.credentials&.config&.dig(SHARED_KEY, :app_url).to_s
    rescue => e
      ::Rails.logger&.warn("[sparrow_auth] could not read credentials: #{e.class}")
      ""
    end

    # What the product is called, as the control panel's front page recorded it.
    #
    # Shown to a person rather than matched against anything — it is the name in
    # the passkey prompt their operating system draws, and the name mail can
    # come from. Blank when nobody has said.
    def application_name
      return "" unless defined?(::Rails) && ::Rails.respond_to?(:application)

      ::Rails.application&.credentials&.config&.dig(SHARED_KEY, :app_name).to_s
    rescue => e
      ::Rails.logger&.warn("[sparrow_auth] could not read credentials: #{e.class}")
      ""
    end

    # ...and just its host, which is what a passkey binds to.
    #
    # nil rather than a guess for anything unparseable or missing a host, so a
    # caller falls back to its own last resort rather than to rubbish. A domain
    # guessed wrongly here is every enrolled passkey broken.
    # The host of the configured application address, lower-cased.
    #
    # Lower-cased because a passkey's relying-party id is compared against the
    # origin's effective domain case-sensitively, while URI.parse preserves
    # whatever was typed -- so "https://EXAMPLE.COM" yields "EXAMPLE.COM" and
    # every passkey silently fails to enrol or verify. That failure does not
    # degrade: it is total, and the repair is asking everybody to enrol again.
    def application_host
      uri = URI.parse(application_url)
      uri.host.presence&.downcase
    rescue URI::InvalidURIError
      nil
    end

    # Run a query, or a whole operation, across every tenant.
    #
    #   SparrowAuth.across_all_organizations(reason: "nightly billing rollup") do
    #     Invoice.where(issued_on: yesterday).find_each { |invoice| ... }
    #   end
    #
    # There are real reasons to cross tenant boundaries — a nightly job, an
    # operator console, a migration — and pretending otherwise only guarantees
    # somebody reaches for `unscoped` instead and leaves nothing behind to find.
    #
    # So this exists, and it is built to be noticed. The reason is required and
    # cannot be blank, which makes it impossible to type by reflex and turns
    # every use into a sentence somebody had to write. It logs at warn level.
    # And the whole thing is one term to grep for: reviewing every cross-tenant
    # query in an application is a single search, and anything not on that list
    # is either scoped or a bug.
    #
    # It restores the previous state rather than clearing it, so nesting cannot
    # end with tenancy silently disabled for the rest of the request.
    def across_all_organizations(reason:)
      stated = reason.to_s.strip
      if stated.empty?
        raise ArgumentError,
          "across_all_organizations needs a reason. It is written into the log " \
          "beside the queries it permits, and it is what makes a cross-tenant " \
          "query reviewable later."
      end

      previous = Current.unscoped_reason
      Current.unscoped_reason = stated

      logger&.warn("[sparrow_auth] across_all_organizations reason=#{stated.inspect}")

      yield
    ensure
      Current.unscoped_reason = previous
    end

    # Call a configured hook, if the application set one.
    #
    # Hooks are the application's code running inside the engine's flow, so a
    # hook that raises would fail the sign-in or the invitation that triggered
    # it. That is deliberate for anything that provisions: an account whose
    # organization was never created is worse than a failed sign-in it can
    # retry. Applications that disagree rescue inside their own hook.
    def run_hook(name, *args)
      hook = config.public_send(name)
      return nil if hook.nil?

      hook.call(*args)
    end

    # Record that an account has signed in, and fire the first-signin hook the
    # first time only.
    #
    # A conditional update rather than a read-then-write, so two sessions
    # starting at once cannot both see a null and both run the hook. The hook
    # fires only for whichever update actually claimed the row.
    def record_first_signin(account)
      return if account.nil?

      # The attribute check matters as much as the value. After creating an
      # account through OmniAuth, Rodauth hands back a model carrying only the
      # columns it inserted, so asking this one for its value raises rather
      # than answering. The conditional update below is the actual guard; this
      # is only here to skip a write on the overwhelmingly common path.
      return if account.has_attribute?(:first_signed_in_at) &&
        account.first_signed_in_at.present?

      claimed = Account.where(id: account.id, first_signed_in_at: nil)
        .update_all(first_signed_in_at: Time.current)
      return if claimed.zero?

      run_hook(:after_first_signin, account.reload)
    end

    def logger
      return nil unless defined?(Rails) && Rails.respond_to?(:logger)

      Rails.logger
    end
  end
end
