# frozen_string_literal: true

module SparrowPay
  # Everything this gem raises descends from here, so an application can rescue
  # the lot in one place if it wants to.
  class Error < StandardError; end

  # A processor this gem has no checkout or portal for.
  #
  # Raised rather than degraded, unlike a plan lookup. A plan's name is
  # decoration and can fall back to an id; a checkout cannot fall back to
  # anything, and a redirect to nowhere is worse than an error naming what to
  # register.
  class Unsupported < Error; end

  # The processor could not tell us about a plan.
  #
  # Never raised where it would break a page: plan details are a nicety for a
  # billing screen, and a provider having a bad afternoon must not take the
  # screen down with it. Callers get a Plan carrying just the id, and this is
  # what a caller sees only if it asked to be told.
  class PlanLookupFailed < Error; end
end
