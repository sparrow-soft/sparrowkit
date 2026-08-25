# frozen_string_literal: true

# The host application's answer to "what happens when somebody first signs in".
#
# This is one earlier application's system-organization logic and another earlier application's auto-org, living where
# the brief says they belong: in the application, not in the engine. The engine
# knows only that a first sign-in happened. Whether that means a personal
# organization, a trial, a profile row, or nothing at all is a product decision,
# and every product in the portfolio answers it differently.
#
# It exists in the dummy application so the suite exercises a real hook
# implementation rather than a stub that only proves the hook was called.
class PersonalOrganizationProvisioner
  def self.call(account)
    return if account.memberships.any?

    SparrowAuth::Organization.create_with_owner!(
      account: account,
      name: "#{account.email.split("@").first}'s workspace"
    )
  end
end
