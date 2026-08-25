# frozen_string_literal: true

require_relative "sparrow_pay/version"
require_relative "sparrow_pay/errors"
require_relative "sparrow_pay/configuration"
# Guarded on Rails rather than on Rails::Engine. The latter is only defined
# once something has required rails/engine, which depends on the order a host's
# application.rb happens to use — and when the guard is false this loads
# nothing, silently, so Pay is absent and the first initializer to mention it
# fails on an uninitialized constant a long way from the cause.
require_relative "sparrow_pay/engine" if defined?(Rails)

# An abstraction over a third-party billing service, for SparrowKit
# applications.
#
# The job is to make Paddle or Stripe easy to wire up and easy to read from,
# and to stop there.
#
# Products, prices, plan names and what they cost are configured at the
# processor, because that is where a developer already configures them. What a
# plan unlocks is the application's business, because Paddle has never heard of
# your feature names. So this gem answers two questions and does not have
# opinions beyond them:
#
#   Is this organization paid up?   organization.billing.active?
#   What are they on?               organization.billing.plan
#
# An application gates on those. It is not this gem's place to decide what
# "growth" means, and a version of it that did meant declaring every plan twice.
#
# Pay owns everything below: the API calls, webhook ingestion and verification,
# the customer and subscription lifecycle, and the differences between the
# processors. If something here starts to look like a processor integration it
# belongs in Pay, with one deliberate exception — fetching a plan's name and
# price, which Pay does not carry and a billing page needs.
#
# One rule is not configurable: the organization is the customer, never the
# person. A person can belong to several organizations and can leave, so a
# subscription attached to a person walks out of the door with them.
module SparrowPay
  # The top-level key this gem reads in the host's Rails credentials, named
  # after the gem so that a developer looking at `credentials:edit` can see
  # whose settings those are without being told.
  #
  # The PROCESSOR's keys are not here and must not be. Pay reads `stripe:`,
  # `paddle_billing:` and so on from the top level of the same file and always
  # has; moving them under this key would write a file Pay cannot see.
  CREDENTIALS_KEY = :sparrow_pay

  # What is in `sparrow_pay:` in the host's credentials, or {}.
  #
  # Read here rather than through sparrow_ui, which is where it used to come
  # from -- and sparrow_ui is a development-group gem, so in production the
  # constant is undefined, the initializer returned early, and every setting the
  # panel had written was silently ignored. `default_processor` stayed nil and
  # the first billing call raised.
  #
  # A missing key, a missing master key and an unreadable file are all the same
  # ordinary state and none of them stops an application booting.
  def self.credentials
    return {} unless defined?(::Rails) && ::Rails.respond_to?(:application)

    value = ::Rails.application&.credentials&.config&.dig(CREDENTIALS_KEY)
    value.is_a?(Hash) ? value : {}
  rescue => e
    ::Rails.logger&.warn("[sparrow_pay] could not read credentials: #{e.class}")
    {}
  end

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
  end
end
