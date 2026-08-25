# SparrowKit — instructions for an AI agent

You are building a Rails application that uses SparrowKit. This file is
everything you need to use it correctly. Read it before writing code that
touches authentication, tenancy, email or billing.

**The single most important rule:** every method, class and setting named in
this file exists. Nothing else does. If you find yourself reaching for an API
that feels like it should be here but is not named below, it is not there —
check the "What does not exist" section at the end before inventing it. Two
invented methods have already reached production code by looking plausible.

## What SparrowKit is

Four Rails engines and a control panel:

| Gem | What it does |
|---|---|
| `sparrow_auth` | Accounts, sign-in, organizations, memberships, invitations, tenant isolation |
| `sparrow_mail` | Sending email through a provider you choose |
| `sparrow_pay` | Subscription billing, on top of the Pay gem, billing the organization |
| `sparrow_ui` | A development-only control panel at `/sparrowkit` for configuring the other three |

Use one or all of them. They are ordinary Rails engines: models, controllers,
migrations, all where you expect.

## What SparrowKit deliberately does not do

Getting this wrong is the most common failure, so it comes before the API.

**It ships no screens.** No sign-in page, no invitation page, no member list,
no organization switcher, no billing page. Rodauth serves its own pages under
`/auth`; everything a customer of yours looks at, you write. There is no
generator that writes them for you.

**It does not decide what a role may do.** There is no permission API, no
policy object, no role ladder and nothing to register. A role is a *name*.
SparrowKit stores it and never interprets it. Authorization rules are ordinary
Ruby in your application, because only your application knows what its roles
mean.

**It never enumerates your models.** Tenant scoping is opt-in per model. A gem
you add later cannot break SparrowKit by introducing a table it does not know
about.

## Installing

SparrowKit is **not on RubyGems**. The gems come from the repository, and they
pin each other to an exact version -- `sparrow_auth` requires exactly this
version of `sparrow_mail`, `sparrow_pay` exactly this version of `sparrow_auth`
-- so every gem in the chain has to come from the same source. A bare
`gem "sparrow_auth"` fails to resolve.

One `git` block does all of it. The `glob:` is what lets Bundler resolve the
gems you did not list but depend on, and `tag:` pins you to a release rather
than to whatever `main` holds today:

```ruby
# Gemfile
git "https://github.com/sparrow-soft/sparrowkit.git", tag: "v1.0.1", glob: "gems/*/*.gemspec" do
  gem "sparrow_auth"
  gem "sparrow_mail"
  gem "sparrow_pay"

  group :development do
    gem "sparrow_ui"   # the control panel; never in production
  end
end
```

Comment out the modules you do not want; taking one alone works, because the
glob resolves whatever it depends on from the same source.

```bash
bin/rails sparrowkit:install
```

That mounts each engine, mounts the control panel at `/sparrowkit`, copies each
module's migrations in and applies them. Safe to run again — a second run adds
only what is missing.

**`sparrowkit:install` comes from `sparrow_ui`.** Without the control panel in
the Gemfile that task does not exist; install each module with its own instead:
`bin/rails sparrow_mail:install`, `sparrow_auth:install`, `sparrow_pay:install`.

Settings live in Rails encrypted credentials under `sparrow_auth:` and
`sparrow_mail:`. Read them with `bin/rails credentials:edit`. Never hardcode
them, and never put them in the initializer.

## sparrow_auth

### Signing in

Rodauth serves these, as middleware above the Rails router, at
`config.path_prefix` (default `/auth`):

| Path | What it is |
|---|---|
| `/auth/login`, `/auth/logout` | Signing in and out |
| `/auth/create-account` | Signing up |
| `/auth/verify-account` | Confirming an email address |
| `/auth/webauthn-setup`, `/auth/webauthn-auth` | Enrolling and using a passkey |

Passkeys and email verification are always on and have no off switch. Passwords
are off by default (`config.passwords_enabled`).

Because Rodauth is middleware, its paths do **not** follow your engine mount
point. `config.path_prefix` and your routes have to be told to agree.

### Tenancy — the part that matters most

Two includes. First, in your `ApplicationController`:

```ruby
class ApplicationController < ActionController::Base
  include SparrowAuth::Tenancy
end
```

That gives you exactly two helpers, in controllers and views:

```ruby
current_account       # the signed-in SparrowAuth::Account, or nil
current_organization  # the tenant this request is for, or nil
```

`current_organization` is only ever set when a membership came back with it, so
a request can never be acting for an organization the account does not belong
to. To move somebody between organizations they belong to:

```ruby
switch_organization!(organization)   # refuses a non-member
```

Second, in each of **your** models that holds tenant data:

```ruby
class Invoice < ApplicationRecord
  include SparrowAuth::Tenanted
end
```

Now every query is scoped to the organization in scope, and new rows are stamped
with it automatically — you never write `organization_id` yourself. A query made
with **no** organization in scope raises `SparrowAuth::UnscopedQuery` rather
than returning every tenant's rows. That is the whole design: the failure lands
in development on the first request, not in production the day a second customer
signs up.

To cross tenants on purpose, say so out loud:

```ruby
SparrowAuth.across_all_organizations(reason: "nightly billing rollup") { ... }
```

One honest limit: Rails' `unscoped` and `unscope(where:)` bypass this, as they
bypass any default scope. Nothing can stop that. `across_all_organizations` is
the version that leaves a reason in the code for a reviewer to find.

### Accounts, organizations, memberships

```ruby
SparrowAuth::Account.find_by_email("someone@example.org")
account.verified?
account.closed?
account.passkey?
account.membership_in(organization)    # the membership, or nil
account.membership_in!(organization)   # the membership, or raises NotAMember
account.member_of?(organization)       # => true / false
account.role_in(organization)          # => "owner", or nil

organization = SparrowAuth::Organization.create_with_owner!(
  account: current_account, name: "Acme"
)
organization.memberships
organization.membership_for(account)
organization.owners                    # memberships, not accounts
organization.to_param                  # organizations are addressed by slug

organization.memberships.create!(account: person, role: "reviewer")
SparrowAuth::Membership.with_role("reviewer")
```

### Roles

A role is a string you choose. `"owner"`, `"inventory_manager"`, `"reviewer"` —
whatever your application means. SparrowKit stores it and never ranks, orders or
interprets it.

Write authorization where the decision belongs:

```ruby
before_action :require_admin

def require_admin
  head :forbidden unless current_account&.role_in(current_organization) == "admin"
end
```

If you want something more structured, use a policy library you already know.
SparrowKit has no opinion to conflict with.

**One exception worth knowing:** `Organization#owners` matches the literal
string `"owner"`. It is the only place SparrowKit looks at a role's *value*, and
`sparrow_pay` uses it to decide where a failed-payment notice goes. If your
application uses a different name for its top role, `owners` will be empty —
harmless, but do not expect it to find them.

### Invitations

Use these for somebody who does not have an account yet. For somebody who does,
just create the membership.

```ruby
invitation, token = SparrowAuth::Invitation.invite!(
  email: "newcomer@example.org",
  invited_by: current_account,
  organization: current_organization,
  role: "reviewer",
  url_builder: ->(t) { "https://example.com/invitations/#{t}" }
)

SparrowAuth::Invitation.redeem!(token: params[:token], account: current_account)
```

The token is returned once and never stored — what is kept is a digest, so a
database backup is not a bag of working invitation links. Only an account that
has **proved** it can read mail at the invited address may accept.

**You must set an invitation policy or every organization invitation is
refused:**

```ruby
# config/initializers/sparrow_auth.rb
config.authorize_invitation = lambda do |inviter:, organization:, role:|
  inviter.role_in(organization) == "owner"
end
```

The default refuses, on purpose. An invitation grants whatever role it names and
seating happens on the invitation's authority, so without a policy anybody who
can reach the method could invite their own address as any role, accept it, and
be seated. SparrowKit cannot decide this for you — it does not know what your
roles mean — so it refuses until you do.

### Errors

Rescue `SparrowAuth::AccessError` for refusals. Do **not** rescue
`SparrowAuth::Error`: that also covers `UnscopedQuery`, and turning a tenant
leak into a friendly 403 is the exact failure the design exists to make loud.

| Error | When |
|---|---|
| `NotAMember` | `membership_in!` on an organization they do not belong to |
| `InvalidInvitation` | Malformed, expired, or already accepted |
| `InvitationNotYours` | Accepting account's address does not match, or is unverified |
| `InvitationNotAuthorized` | `authorize_invitation` refused, or none is configured |
| `InvalidCode` | A wrong or expired sign-in code |
| `UnverifiedAccount` | The address has not been confirmed |
| `AccessDenied` | Yours to raise from your own rules; SparrowKit never raises it |
| `UnscopedQuery` | A tenant-scoped query with no organization in scope — a bug |

## sparrow_mail

ActionMailer works exactly as normal; nothing about your mailers changes. Or
send directly:

```ruby
SparrowMail.deliver!(mail)   # raises SparrowMail::DeliveryError
SparrowMail.deliver(mail)    # returns a Result carrying the failure
```

Use `deliver` when a failed send is a value rather than an exception — a bulk
send that must not stop at one bad address:

```ruby
result = SparrowMail.deliver(mail)
unless result.success?
  case result.category
  when :invalid_recipient then subscriber.mark_undeliverable!
  when :rate_limited      then DeferredMailJob.set(wait: 5.minutes).perform_later(...)
  end
end
```

`success?` and `delivered?` differ: a message withheld in sandbox mode is a
success that was not delivered.

Adapters: `mailgun`, `postmark`, `sendgrid`, `ses`, `smtp`, `send_layer`,
`preview`, `test`. Choose one in the control panel or in credentials; swapping
providers changes one setting and nothing else.

## sparrow_pay

**Read this before writing any billing code.** sparrow_pay is deliberately
thin. It does three things and nothing else:

1. Makes the **organization** the customer that gets billed
2. Works out where a receipt should go
3. Gives the developer a panel to choose a processor and enter its API keys

Everything else about billing is the [Pay gem](https://github.com/pay-rails/pay)
and is documented by Pay. Your application talks to Pay directly. There is no
wrapper here to learn.

### The organization is the customer

`SparrowPay::Billable` is included into `SparrowAuth::Organization` by the
engine, in an initializer, automatically.

**Do not include it yourself, and never include it in an `Account`.** That is
the whole point of it being automatic: a person can belong to several
organizations and can leave, so a subscription attached to a person walks out of
the door with them, and an organization's access would depend on which of its
members happened to have paid. Making it impossible to wire the wrong way is the
guarantee.

What that gives an organization:

```ruby
organization.payment_processor              # Pay's customer object
organization.payment_processor.subscribed?  # Pay's API, documented by Pay
organization.payment_processor.subscription
organization.billing_email                  # where a receipt goes
```

`Billable` also defines `pay_customer_name` and `pay_customer_email` for you.
Pay asks the billable model for those; do not override them.

### Where a receipt goes

`billing_email` prefers an **owner** and falls back to any member, so an
organization mid-handover still has somewhere to send a failed-payment notice —
the moment it most needs one.

Note the coupling: "owner" here means a membership whose `role` is the literal
string `"owner"`, via `Organization#owners`. This is the one place in SparrowKit
where a role's *value* means something. If your application names its top role
something else, `billing_email` falls through to the first member — still a real
address, but not the one you probably intended.

### What does not exist

There is **no** `organization.billing` object, no plan catalogue, no billing
status columns, no checkout flow, no billing screens, and nothing emits a
billing notification. An earlier version of SparrowKit mirrored the plan and
status into columns and kept them current from webhooks; it was removed because
a cached second answer can be wrong, and Pay already knows.

Ask Pay. Plans, prices, checkout pages and who may see them are yours.

## The control panel

`sparrow_ui` mounts at `/sparrowkit` in development only. It refuses anything
that is not a local request, in middleware, before routing runs — so it cannot
be reached even if it accidentally ships. Never put it outside the `development`
group.

Use it to configure mail providers, auth settings and billing without editing
files. It reads and writes Rails credentials.

## Testing your application

Tenant isolation is worth testing directly, because the failure mode is silent:

```ruby
it "does not show another organization's invoices" do
  SparrowAuth::Current.with_organization(other) { Invoice.create!(number: "X") }

  SparrowAuth::Current.with_organization(mine) do
    expect(Invoice.count).to eq(0)
  end
end

it "refuses a query with no organization in scope" do
  expect { Invoice.count }.to raise_error(SparrowAuth::UnscopedQuery)
end
```

Reset state between examples with `SparrowAuth::Current.reset`, and configure
`config.authorize_invitation` in your test setup or every invitation spec fails.

## What does not exist

These have all been invented by agents writing against SparrowKit. None of them
are real. Do not use them, and do not write code that assumes them:

| Not real | What to do instead |
|---|---|
| `require_organization!` | Write a `before_action` of your own |
| `skip_authorization!` | Nothing to skip; there is no enforced check |
| `may?(...)`, `permits?(...)` | Compare `role_in(organization)` yourself |
| `at_least: :admin` | There is no ranking; compare the name |
| `SparrowAuth::Role`, `Role.define` | Roles are strings, not objects |
| `SparrowAuth::Authorization` | Use `SparrowAuth::Tenancy` |
| `SparrowAuth::Resolver`, `SparrowAuth::Grant` | Deleted; nothing replaces them |
| `rails generate sparrowkit:screens` | Write the pages yourself |
| `rails generate sparrowkit:resource` | Write the model yourself |
| `current_membership`, `current_role` | Only `current_account` and `current_organization` exist |
| `account.can?(...)`, `sparrow_auth_signed_in?` | Never existed; `current_account` is the check |

## Working on SparrowKit itself

Only relevant if you are changing SparrowKit rather than using it.

```bash
bundle exec rake setup      # install the root bundle and each gem's own
bundle exec rake            # the gate: every suite, versions, licence, docs, vocabulary, standardrb
bundle exec rake spec:docs  # just the documentation check
bundle exec rake audit      # Gemfile.lock against the Ruby Advisory Database
cd gems/sparrow_mail && bundle exec rspec   # one gem's suite, from its own directory
```

**`spec/docs_spec.rb` checks this file against the code.** Every constant,
method and setting named above the "What does not exist" table has to exist in
`gems/*/{lib,app,console}`, and every API named *in* that table has to still be
gone. It also fails if any shipped document teaches a removed API.

So if you delete something, this file is part of the change. That is the point:
both times the documentation drifted, it taught an API that had been deleted
releases earlier, and a person reading was the only thing that caught it.

The gate must exit 0 before anything is committed. `rubocop` and `standardrb`
are the same thing here — `.rubocop.yml` inherits Standard's rules so either
command gives the same answer, and CI runs both so they cannot drift apart.

If a suite fails locally but passes in CI, suspect the test database before the
code: the Postgres test databases are reused, so a constraint from a migration
that no longer exists can survive in one. `dropdb sparrow_auth_test && createdb
sparrow_auth_test` is the first thing to try.

Everything a developer reads — READMEs, the control panel, error messages — is
written in plain English. The test is whether somebody on their first Rails
application could follow it. A name they will actually see in a stack trace,
like `UnscopedQuery`, is not jargon; write it.
