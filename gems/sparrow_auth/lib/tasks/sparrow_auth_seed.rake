# frozen_string_literal: true

# bin/rails sparrow_auth:seed
#
# One account and one organization, so that a brand new application has
# somebody to sign in as.
#
# Without this, a finished install leaves nothing to sign in to. There are no
# accounts, so the sign-in screen answers every address the same way it answers
# a stranger's -- correctly, and uselessly. Creating the first one by hand means
# knowing that an account has to be VERIFIED before a code will be sent to it,
# and that an organization is created through create_with_owner! rather than by
# assigning a membership, neither of which anybody should have to find out on
# their first afternoon.
#
# The account is `you@example.test`. `.test` is reserved by RFC 6761 and
# resolves nowhere, so even an application that later configures a real provider
# cannot deliver anything to a real person by accident. That is the whole reason
# for the address rather than a derived one.
namespace :sparrow_auth do
  desc "Create one verified account and one organization to sign in as"
  task seed: :environment do
    SparrowAuth::Seed.run(reporter: ->(line) { puts line })
  end
end
