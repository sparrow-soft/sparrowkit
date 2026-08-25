# sparrow_auth

Signing people in, and knowing who they are afterwards.

Add this to a Rails application and you get working sign-in pages without
writing any of them. People can create an account, prove they own their email
address, sign in and stay signed in, share an account with colleagues, and be
given different amounts of access to different things.

Underneath it uses [Rodauth](https://rodauth.jeremyevans.net/), a
well-established Ruby library that handles the genuinely dangerous parts —
storing passwords so they cannot be read back, checking a passkey, making sure
a sign-in link cannot be used twice. What this gem adds is the work Rodauth
deliberately leaves to you: shared accounts for teams, deciding who is allowed
to do what, the pages themselves, and the wiring in between.

**What is here:** accounts; email verification that cannot be switched off;
signing in with a code sent by email; passkeys; signing in with Google or Apple;
passwords, which are off unless you turn them on; shared accounts and the people
in them; invitations; and keeping one customer's records away from another's.

**What is not:** any page a customer of yours looks at, and any opinion about
what a role may do. Rodauth serves its own pages under `/auth`; everything else
is yours to write, and authorization is ordinary Ruby in your application.

Part of [SparrowKit](../../README.md). Needs Ruby 3.2 or newer, Rails 8.1 or
newer, and either PostgreSQL 12 or newer, or SQLite 3.9 or newer.

---

## The one rule you cannot switch off

**An email address is not trusted until it has been verified**, and there is no
setting that turns that off.

Somebody typing an address into a box only tells you they can type. It does not
tell you they can open the mailbox. Rodauth offers a grace period that lets
people sign in before verifying; it is not merely set to zero here, the feature
is left out entirely, so no application can turn it back on later.

Plan around it: until somebody has verified, they cannot accept an invitation
and cannot be signed in.

## Installing

```bash
bin/rails sparrow_auth:install
```

One command. It mounts the engine at `/auth`, mounts the SparrowKit control
panel at `/sparrowkit`, copies this engine's database tables in and applies
them, and writes `config/initializers/sparrow_auth.rb`. It runs **only its own
migrations**, never any of yours that happen to be pending, and it is safe to
run again.

Mount somewhere else with `--mount-at=/accounts`.

### What your database has to support

**PostgreSQL 12 or newer**, or **SQLite 3.9 or newer**. Nothing else — MySQL is
not supported, and the installer says so before it writes anything.

Two things in the tables are worth knowing about, because both are the kind of
thing that fails at install time rather than at boot:

- **`citext`, a PostgreSQL extension.** Email addresses and organization slugs
  are stored in a case-insensitive column, so `Victim@example.com` and
  `victim@example.com` are one address at the database level rather than only in
  whichever Ruby method remembered to lower-case them. The migration enables the
  extension itself, which needs the `postgresql-contrib` package installed —
  present by default on Heroku, Amazon RDS and Homebrew, and a separate install
  on some Linux distributions. On SQLite the same columns use the `NOCASE`
  collation, which needs nothing extra.
- **Partial indexes**, which is where the SQLite floor comes from. Several rules
  apply to some rows and not others — one live account per address, counting
  only the accounts that have not been closed; one live invitation per address
  per organization, counting only the ones nobody has accepted yet.

Deliberately nothing newer. The obvious way to write the invitation rule is
PostgreSQL's `NULLS NOT DISTINCT`, which would put the floor at PostgreSQL 15
for one clause; it is written as two indexes over separate sets of rows instead,
which every supported version of both databases understands.

If you move the mount point afterwards, one thing does not follow automatically.
Rodauth serves its routes above the Rails router, so its paths are not derived
from where you mounted the engine, and the two have to be told to agree:

```ruby
SparrowAuth.configure { |config| config.path_prefix = "/accounts" }
```

## Configuring

Two places, and which one depends on whether the value is code.

**Values** — the domain passkeys bind to, where mail comes from, which ways in
are open, the signing keys — are set at `http://localhost:3000/sparrowkit/auth`
and stored under `sparrow_auth:` in your Rails encrypted credentials. They are
deliberately *not* settable in the initializer, which is evaluated after
credentials are read and would silently win.

**Code** — the callbacks that tell your application something happened, any role
you declare beyond the five that ship, and provider options a text box cannot
express — goes in `config/initializers/sparrow_auth.rb`:

```ruby
SparrowAuth.configure do |config|
  config.mail_from          = "Example <no-reply@example.com>"
  config.invitation_expiry  = 7 * 86_400
  config.after_verification = ->(account) { Organization.create_personal_for(account) }
end
```

### The three that need a decision

| Setting | Default | Why it matters |
|---|---|---|
| `webauthn_rp_id` | your application's address, from the control panel's home page | The domain a passkey is permanently tied to. It cannot be moved to another, so getting this wrong is fixed by asking every user to enrol again, not by changing the setting. Usually leave it alone and set the address instead; set this only when passkeys need a **different** domain from the site — `example.com` for a site at `www.example.com`, so they work on every subdomain. |
| `mail_from` | sparrow_mail's `default_from` | Auth mail has to come from somewhere. |
| `passwords_enabled` | `false` | Whether the one credential that can be phished, reused and guessed at scale exists at all. Off is a complete configuration. |

### Which ways in

Two of them are settled and have no setting. **Passkeys are always on** — they
are the primary way in and the only one that cannot be phished, guessed or
reused from somebody else's breach. **Email verification is always on** — an
unverified address is a claim, not an identity.

Emailed sign-in is always available too, because a brand new account has no
passkey yet and would otherwise have no way in at all. What you choose is its
shape:

| Setting | Default | Meaning |
|---|---|---|
| `emailed_sign_in` | `:code` | A six-digit code somebody types, or `:link` for one they open. One or the other, never both and never neither. |
| `emailed_sign_in_link_expiry` | 10 minutes | How long a link lasts. The same as a code, so there is one number to explain. |

**Which to choose.** A code works when the mail is read somewhere else — a
phone, a shared mailbox, a machine that is not the one they started on. A link
is one click and cannot be finished anywhere but the browser that asked for it,
which is exactly what stops anything scanning the mailbox from spending it, and
exactly what makes "read it on my phone, finish on my laptop" impossible.
Neither is more secure than the other; they fail in different places.

One thing follows from choosing links: **a link cannot create an account.** It
has to hang on an account that already exists, so with links chosen, an address
nobody has yet gets a "you have no account here" email instead, and new people
arrive by invitation or through create-account.

Passwords are separate, and off by default:

| Setting | Default | Meaning |
|---|---|---|
| `passwords_enabled` | `false` | Whether passwords are a way in at all. Off is a complete configuration, not a crippled one. |
| `password_minimum_length` | `12` | Minimum length when passwords are on. |
| `password_breached` | none | Called with a candidate password; return true to refuse it. |
| `signup_with_code` | `true` | Whether redeeming an emailed code for an unknown address creates a verified, passwordless account. |
| `social_providers` | `{}` | Google and Apple. Set these on the control panel, which also tells you which gem each needs. Empty means the feature is off entirely. |

### Setting up new accounts

These are how the engine tells you something happened, so you can make whatever
your application needs alongside it — a profile row, a trial, a welcome email.

None of them has a default, and one of them used to. `after_first_signin` gave
every new account an organization of its own, which meant everybody who signed
in became the owner of one — holding `organization:delete`,
`organization:transfer`, `members:manage` and `billing:manage`. Nobody asked for
that, and an engine guessing at it hands out standing nobody chose. What a fresh
application needs instead is one account to test with, and
`bin/rails sparrow_auth:seed` makes exactly that.

| Setting | Default | Meaning |
|---|---|---|
| `after_first_signin` | none | Called with the account the first time it signs in, however it signed in, and never again. |
| `after_verification` | none | Called with the account after it first verifies. |
| `after_invitation_accepted` | none | Called with `(account, invitation)`. |
| `authorize_invitation` | none | Callable given `(inviter:, organization:, role:)`, returning true to allow. Required: with none set, every organization invitation is refused. |
| `after_organization_created` | none | Called with `(organization, created_by)`. |
| `after_accept_path` | `/` | Where to go after accepting an invitation. |

### Organizations and roles

| Setting | Default | Meaning |
|---|---|---|
| `organization_for_request` | built-in | Decides which organization the current request is for. The default takes an explicit choice from the session, then the account's only membership if it has exactly one, and never guesses between several. |

### Rarely changed

| Setting | Default | Meaning |
|---|---|---|
| `path_prefix` | `/auth` | Where Rodauth serves. Must match your mount point. |
| `emailed_sign_in` | `:code` | Whether an emailed sign-in is a six-digit code somebody types or a link they open. One or the other, never both and never neither. |
| `emailed_sign_in_link_expiry` | 10 minutes | How long a sign-in link lasts. Matches the code. |
| `sign_in_path` | `/sign-in` | Where your own sign-in screen lives. The generated one goes here; Rodauth's pages and the test helpers link to it. |
| `sign_in_code_path` | `/sign-in/code` | The second step of that screen. Follows `sign_in_path` unless you set it. |
| `mail_stream` | `:transactional` | Auth mail must never ride a bulk sending reputation. |
| `verify_account_expiry` | 24 hours | How long a verification link lasts. |
| `invitation_expiry` | 7 days | How long an invitation lasts. |
| `webauthn_origin` | from the request | The full address passkeys are registered against. |
| `webauthn_rp_name` | your product's name, from the control panel's home page | What the operating system's prompt calls you. Set the **name** there and this follows it; set this only when the prompt should say something other than the product's name. With neither, people see the domain, which reads like a machine talking. |
| `otp_secret` | derived | The secret the stored fingerprints of emailed codes are computed with. |

## Before you deploy

**Turn on the things Rails ships for this.** None of them is SparrowKit's to
switch on for you, and an authentication product that never mentions them is
leaving the most important part unsaid:

```ruby
# config/environments/production.rb
config.force_ssl = true
```

That one line does three jobs: it redirects http to https, it sends
`Strict-Transport-Security` so a browser stops trying http at all, and it marks
every cookie `secure` — including the session cookie that says who is signed in.
Without it, a session cookie travels in clear text on the first request of every
visit, and a passkey will not work at all, because WebAuthn requires a secure
origin.

Rails already sets `HttpOnly` and `SameSite=Lax` on the session cookie, which is
what you want: `HttpOnly` keeps it away from any JavaScript on the page, and
`SameSite=Lax` is what makes a cross-site form post arrive without it. Leave
both alone unless you have a specific reason, and if you set `SameSite=None` for
an embedded context, know that you have turned off a CSRF defence and need
another.

Sessions here are rows rather than only cookies — every sign-in writes one, so
you can build a page that lists them and ends any of them. A stolen cookie can
therefore be revoked, which a cookie-only session cannot.

**Tell Rails which proxies to trust.** Every rate limit here counts against
`request.remote_ip` — one code per address per minute, ten per IP per hour, and
the throttles on the password path. Rails works `remote_ip` out by walking
`X-Forwarded-For`, trusting the entries that came from a proxy it knows about,
and behind a load balancer or CDN it cannot know yours unless you say:

```ruby
# config/environments/production.rb
config.action_dispatch.trusted_proxies = [
  IPAddr.new("10.0.0.0/8")   # your load balancer's range
]
```

Without it, a client can add its own `X-Forwarded-For` header and be counted as
a different visitor on every request, which is a rate limit that does not limit
anybody. With it, the header is trusted only as far as your own infrastructure.

The alternative — counting the socket address instead — is worse in the ordinary
case: behind a load balancer every request arrives from the same address, so one
abusive client would rate-limit every user of the application at once.

## The screens

sparrow_auth serves the pages Rodauth serves and nothing else:

| Path | What it is |
|---|---|
| `/auth/login`, `/auth/create-account` | Signing in with a password, and signing up |
| `/auth/verify-account` | Confirming an email address |
| `/auth/webauthn-setup`, `/auth/webauthn-auth` | Enrolling and using a passkey |

Everything a customer of yours looks at is yours to write. sparrow_auth gives
you the models and the request-level tenancy, and stops there:

| You write | Using |
|---|---|
| Sign-in and sign-up | Rodauth's own routes under `/auth`, or your own form posting to them |
| Landing from an invitation | `SparrowAuth::Invitation.redeem!(token:, account:)` |
| Who is in an organization | `organization.memberships` |
| Somebody's passkeys | Rodauth's `/auth/webauthn-setup` and the credentials on the account |
| Active sessions | `SparrowAuth::Session` rows |
| Connected Google/Apple accounts | `SparrowAuth::Identity` rows |

They are generated rather than served because every one of them carries your
navigation, your words and your styling. A page shipped from a gem is a page
you would replace on the first afternoon.

## Using it

**Invitations.** The token comes back once and is never stored:

```ruby
invitation, token = SparrowAuth::Invitation.invite!(
  email: "newcomer@example.org",
  invited_by: current_account,
  url_builder: ->(t) { "https://example.com/auth/invitations/#{t}" }
)

SparrowAuth::Invitation.redeem!(token: params[:token], account: current_account)
```

Redeeming raises rather than returning false. The address must match, the
account must be verified, and it must not be closed.

**Organizations and roles.** Creating an organization and seating its first
member is one act, so an organization never exists without one:

```ruby
organization = SparrowAuth::Organization.create_with_owner!(
  account: current_account, name: "Acme"
)

account.role_in(organization)      # => "owner"
account.member_of?(organization)   # => true
account.membership_in!(organization) # the membership, or raises NotAMember
```

A role is a **name and nothing more**. sparrow_auth stores it and never
interprets it: there is no ladder, no ranking, and no notion of one role
outranking another. Use whatever names your application means -- `"owner"`,
`"inventory_manager"`, `"reviewer"` -- and decide what they permit in your own
code, because only your code knows.

Adding somebody who already has an account:

```ruby
organization.memberships.create!(account: person, role: "reviewer")
```

**Keeping one customer's records away from another's.** Two lines:

```ruby
class Invoice < ApplicationRecord
  include SparrowAuth::Tenanted
end

class ApplicationController < ActionController::Base
  include SparrowAuth::Tenancy
end
```

Every query is then limited to the organization the request belongs to, and a
query made when none has been established **stops with an error** rather than
quietly returning everything. When you genuinely need to cross between
customers, say so out loud:

```ruby
SparrowAuth.across_all_organizations(reason: "nightly billing rollup") { ... }
```

**Deciding who may do what is yours.** sparrow_auth deliberately ships no
permission API, no policy object and nothing to register. It cannot decide for
you, because it does not know what your roles mean.

Write the rule where the decision belongs, in ordinary Ruby:

```ruby
class InvoicesController < ApplicationController
  include SparrowAuth::Tenancy

  before_action :require_admin

  private

  def require_admin
    head :forbidden unless current_account&.role_in(current_organization) == "admin"
  end
end
```

That is the whole story. "Only the author may edit this one" is an `if` in the
action. If you want something more structured, reach for a policy library you
already know -- sparrow_auth will not get in its way, because it has no opinion
to conflict with.

What sparrow_auth *does* guarantee is that a request cannot be acting for an
organization the account does not belong to: `current_organization` is only set
when a membership came back with it.

## Generators

There is one, and the install task runs it for you:

```bash
bin/rails generate sparrow_auth:install
```

It writes the initializer and copies the migrations in. It is safe to run again
-- it adds only what is missing.

sparrow_auth writes no screens and no scaffolding into your application. The
pages your customers see are yours to write, carrying your navigation, your
styling and your words.

## Making the pages yours

Rodauth's pages render through `SparrowAuth::RodauthController`, which sets
`layout "application"` -- your application's own layout, so they arrive already
wrapped in your header, footer and styling. There is nothing to theme here and
no stylesheet of ours to override.

`bin/rails generate rodauth:views` copies Rodauth's templates into your
application when you want to change the markup itself. Point
`config.rails_controller` at a controller of your own if you want your
before_actions on those pages too.

## Keeping two tables from growing forever

```bash
bin/rails sparrow_auth:prune
```

Two of the tables this gem creates gain a row on activity and lose one only when
something deletes it, and both hold personal data while they wait.

`sparrow_auth_auth_events` is one row per sign-in attempt of any kind — an email
address or an IP address beside a timestamp. Its only job is answering "how many
of these in the last few minutes", so a row older than the longest rate-limit
window answers nothing, and a year of them is a record of who tried to sign in
to what and from where.

`sparrow_auth_otp_codes` is an email address beside a scrambled copy of a
sign-in code. Once the code has expired the row cannot be used to sign in, so
what is left is an address and a secret with nothing to unlock.

The task deletes exactly those two kinds of row and nothing else, prints what it
removed, and takes no arguments. Run it on whatever schedule the application
already has for periodic work — daily is generous, hourly is fine. It reads the
rate-limit windows rather than assuming them, so a longer limit you configure
later does not start having its counters deleted underneath it.

## Known gaps

- **The forgotten-check error only covers controllers.** Background jobs,
  mailers and console work have no request to attach it to. Ask the membership
  directly there: `account.membership_in!(organization)`, then check the role.
- **Rails' `unscoped` still gets past the tenant rules**, as it gets past any
  default scope. No gem can stop it.
- **There are no screens at all** — no sign-in page, no invitation page, no
  member list, no organization switcher. Rodauth serves its own pages under
  `/auth`; everything else is yours to write against the models above.
- **Rate limits are per address and per IP**, so they are not a defence against
  a large distributed attack. They stop the cheap one, which is the one that
  happens.
- **What customers do is not logged.** Staff activity is; there is no equivalent
  on the customer side.

Deliberately out of scope for version 1: signing in through a company's own
identity provider (SSO and SAML), any second factor beyond passkeys and emailed
codes, a customer-facing activity log, and tools for deleting an account or
answering a GDPR request.

## Further reading

Why each of these rules exists, what happens if you do it the other way, how
sign-in is kept from revealing who has an account, how the back office and its
audit trail work, and the full security model are covered above.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
