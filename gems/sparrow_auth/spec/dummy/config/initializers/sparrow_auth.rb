# frozen_string_literal: true

# Social sign-in is configured here, at boot, because SparrowAuth.config.social?
# is read when RodauthMain's configure block runs — which is once, at class load.
# A spec cannot turn the feature on afterwards, and that is correct: whether an
# application has social sign-in is a deployment decision, not a per-request one.
#
# OmniAuth's own developer strategy stands in for Google and Apple. The rules
# being tested are ours and are provider-independent: what a provider asserts
# about an email, and what this engine will and will not do with it.
require "omniauth"

OmniAuth.config.logger = Logger.new(IO::NULL)
OmniAuth.config.allowed_request_methods = [:post]

SparrowAuth.configure do |config|
  # The suite's invitation policy. SparrowKit refuses every invitation into an
  # organization until the application states one, so the dummy application has
  # to say something -- here, that any member of the organization may invite.
  config.authorize_invitation = lambda do |inviter:, organization:, role:|
    inviter.membership_in(organization).present?
  end

  config.social_providers = {developer: []}

  # The apps a token may be issued for. One earlier application's two, because the audience claim
  # exists for exactly that shape: one identity that legitimately spans both.
end
