# frozen_string_literal: true

module SparrowPay
  # What the host application decides.
  #
  # Short on purpose. This gem is an abstraction over a third-party billing
  # service, not a billing system of its own: products, prices, plan names and
  # what any of them cost live at Paddle or Stripe, where the developer already
  # configured them, and restating them here would be two places to change and
  # a guarantee they drift.
  class Configuration
    # How long a plan's name and price are held before asking the processor
    # again. Plans change rarely and a billing page is read often, so this is
    # measured in hours rather than minutes.
    attr_accessor :plan_cache_for

    # THERE IS NO billing_resolver, AND THAT IS THE FIX RATHER THAN AN OMISSION.
    #
    # This gem carried its own copy of the per-record policy pattern -- a class
    # name saying who could read and change billing -- and it outlived that
    # pattern by a whole release. sparrow_auth dropped it in 0.1.0, along with
    # the billing pages this setting guarded, so what was left was a text box on the
    # Payments panel asking for the name of a class that could not be written,
    # to protect pages that no longer existed, warning in amber that until it was
    # filled in "the billing pages refuse everybody".
    #
    # Who may see and change billing is the application's own rule, written in
    # its own controller against the role the membership holds. SparrowKit
    # stores role names and never interprets them, so it cannot decide this.

    # Which processor an organization gets when it first needs one.
    #
    # Named rather than guessed. Pay allows several at once and an application
    # that has not said which it uses should be told, not assigned one.
    attr_accessor :default_processor

    # Whether Pay's fake processor may be used.
    #
    # False, and it has to be said out loud to be true. Pay refuses the fake
    # processor unless asked, which is the right way round: an application that
    # fell back to it would take no money and say nothing about it. This carries
    # that decision rather than the controller comparing against the name, which
    # would put a processor's name outside the seams that are allowed to know
    # one.
    attr_accessor :allow_fake_processor

    def initialize
      @plan_cache_for = 12.hours
      @default_processor = nil
      @allow_fake_processor = false
    end

    def inspect
      "#<SparrowPay::Configuration plan_cache_for=#{plan_cache_for.inspect}>"
    end
  end
end
