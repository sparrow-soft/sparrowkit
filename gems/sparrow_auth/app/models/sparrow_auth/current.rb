# frozen_string_literal: true

module SparrowAuth
  # Who is asking, and which tenant they are asking about.
  #
  # CurrentAttributes rather than a thread-local of our own, because Rails
  # already resets these between requests and between jobs. A tenancy scope that
  # leaked from one request into the next would be the worst possible bug in
  # this engine: it would serve one customer's rows to another, intermittently,
  # under load, and only on a reused thread.
  class Current < ActiveSupport::CurrentAttributes
    attribute :account
    attribute :organization

    # Set only inside SparrowAuth.across_all_organizations, and holding the
    # stated reason rather than a bare `true`. A boolean here would say that
    # some code somewhere decided to cross tenant boundaries; the reason says
    # which code and why, in the log line and in the stack.
    attribute :unscoped_reason

    def scoped?
      organization.present?
    end

    # Runs a block with one organization in scope, and puts back whatever was
    # there before — including nil.
    #
    #   SparrowAuth::Current.with_organization(acme) { Invoice.count }
    #
    # Assigning Current.organization directly works too, and is what a request
    # does once per request. This is for everything else: a job handling several
    # tenants in turn, a console, a spec. Those are the places where a scope
    # left set after the work is done is a scope the next piece of work
    # inherits, and an organization leaking sideways is the one bug this whole
    # arrangement exists to prevent.
    def self.with_organization(organization)
      previous = self.organization
      self.organization = organization
      yield
    ensure
      self.organization = previous
    end
  end
end
