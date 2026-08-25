# frozen_string_literal: true

module SparrowAuth
  # The first account and the first organization.
  #
  # A plain module rather than a rake task body, so that the installer and the
  # task can both call it and neither has to shell out to the other, and so that
  # what it decides can be tested without a Rake runtime.
  #
  # WHY THERE IS ANY OF THIS. A finished install leaves nothing to sign in as.
  # An account has to be verified before a sign-in code will be sent to it, and
  # the first organization has to be created through
  # Organization.create_with_owner! rather than by assigning a membership --
  # because assigning one asks who is doing the assigning, and at this point
  # nobody is. Neither of those is obvious, and both are things somebody would
  # otherwise discover by getting them wrong.
  module Seed
    # `.test` is reserved by RFC 6761 and resolves nowhere on the public
    # internet. That is the point rather than a stylistic choice: an application
    # that later configures a real provider still cannot deliver anything to a
    # real person from this row.
    #
    # Deriving it from the developer's git config was the alternative, and it
    # would put a working address into a database and into mail our own control
    # panel can send.
    EMAIL = "you@example.test"

    # The environments this may run in, as an allowlist.
    #
    # Not "refuses production". A staging environment must not seed either, and
    # a denylist naming one environment says nothing about the others.
    ENVIRONMENTS = %w[development test].freeze

    class RefusedEnvironment < Error; end

    module_function

    # Creates what is missing and reports what it did.
    #
    # Idempotent, keyed on the address: a second run finds the account and
    # changes nothing. It never touches an account it did not create, so running
    # it in an application that already has people is safe as well as pointless.
    def run(reporter: nil)
      refuse_the_environment!

      account = existing_account
      created = account.nil?
      account ||= create_account

      organization = organization_for(account) || create_organization(account)

      report(reporter, account: account, organization: organization, created: created)

      {account: account, organization: organization, created: created}
    end

    # Whether there is anybody at all yet.
    #
    # What the installer asks before seeding: a fresh application gets a seed, an
    # existing one with real accounts is left alone. Asked of the whole table
    # rather than of this one address, because an application with its own people
    # in it does not want a fake organization beside their real ones.
    def wanted?
      allowed_environment? && !Account.exists?
    end

    # What `sparrow_auth:install` calls: seed if the application has nobody, and
    # hand back the lines worth putting in the closing summary.
    #
    # A failure here does not fail the install. Everything sparrow_auth actually
    # needs is written by the time this runs, so a seed that could not be
    # created is a thing to say and carry on from -- not a reason to abort an
    # otherwise finished install and leave somebody working out which half of it
    # happened.
    def during_install
      return [] unless wanted?

      result = run

      [
        "You can sign in as #{result[:account].email}, who owns #{result[:organization].name}.",
        "Ask for a code at /sign-in; the control panel shows it while no mail provider is set."
      ]
    rescue => e
      ["No starting account was created (#{e.class}). Run bin/rails sparrow_auth:seed to try again."]
    end

    def allowed_environment?
      ENVIRONMENTS.include?(Rails.env.to_s)
    end

    def refuse_the_environment!
      return if allowed_environment?

      raise RefusedEnvironment,
        "sparrow_auth:seed creates an account that anybody who knows this " \
        "product can sign in as, so it runs in #{ENVIRONMENTS.join(" and ")} " \
        "and nowhere else. This is #{Rails.env}."
    end

    def existing_account
      Account.find_by_email(EMAIL)
    end

    # Verified on creation, because an unverified address is not sent a sign-in
    # code -- so a seeded account that was not verified could not sign in, which
    # is the one thing it exists to do.
    def create_account
      Account.create!(email: EMAIL, status_id: Account::VERIFIED)
    end

    def organization_for(account)
      account.organizations.first
    end

    # create_with_owner!, not Membership.assign!. Assigning asks who is doing
    # the assigning and refuses a role above their own; here there is nobody to
    # ask. That is a different code path rather than a way around the rule, and
    # keeping it that way is why the role ceiling has no override flag.
    def create_organization(account)
      Organization.create_with_owner!(account: account, name: application_name)
    end

    # The application's own name, so the organization reads like theirs rather
    # than like ours. Falls back to something plainly generic rather than to a
    # class name with the word Application in it.
    def application_name
      name = Rails.application.class.module_parent_name.to_s
      return "Your organization" if name.empty? || name.casecmp("rails").zero?

      name.underscore.humanize
    end

    def report(reporter, account:, organization:, created:)
      return unless reporter

      if created
        reporter.call("Created #{account.email}, an owner of #{organization.name}.")
      else
        reporter.call("#{account.email} is already here, owning #{organization.name}. Nothing changed.")
      end

      reporter.call("Sign in as it at /sign-in — the code is emailed, and the control panel shows it.")
    end
  end
end
