# sparrow_pay

Taking money, on a subscription, from a team rather than from one person.

**This gem is deliberately thin, and thinner than you probably expect.** The
[Pay gem](https://github.com/pay-rails/pay) does all of it: the API calls, the
webhooks, the subscription lifecycle. sparrow_pay adds two things and stops —
a control panel for choosing your processor and storing its API keys, and the
decision that the customer is an organization rather than a person.

Your application talks to Pay directly. There is no wrapper here to learn.

```ruby
organization.payment_processor              # Pay's customer object
organization.payment_processor.subscribed?  # Pay's API, documented by Pay
organization.billing_email                  # an owner's address, for receipts
```

The organization is the customer, never a single person. Somebody can belong to
several organizations and can leave, so a subscription attached to a person
walks out of the door with them.

`SparrowPay::Billable` is included into `SparrowAuth::Organization` by the
engine, automatically. Do not include it yourself, and never include it in an
account model — making the wrong wiring impossible is the guarantee, rather than
a convention somebody has to remember. It also defines `pay_customer_name` and
`pay_customer_email`, which Pay asks the billable model for; leave those alone.

Everything else — what plan someone is on, whether they are past due, when they
renew — you ask Pay.

## Installing

```ruby
# Gemfile
#
# Not on RubyGems yet, and the four gems pin each other to an exact version, so
# they all come from the repository in one `git` block. Comment out what you do
# not want.
git "https://github.com/sparrow-soft/sparrowkit.git", tag: "v1.0.1", glob: "gems/*/*.gemspec" do
  gem "sparrow_auth"
  gem "sparrow_pay"
end
```

Then the migrations, and whichever processor you use — that part is Pay's, and
its documentation is the one to follow:

```bash
bin/rails sparrow_pay:install:migrations
bin/rails db:migrate
```

```ruby
# config/initializers/sparrow_pay.rb
SparrowPay.configure do |config|
  config.plan_cache_for = 12.hours   # how long a plan's name and price are held
end
```

**Who may see and change billing is not configured here**, because SparrowKit
does not decide what a role may do. Billing belongs to an organization, and who
may read or change it is your rule, written in your own controller where you can
read it and test it:

```ruby
before_action :require_billing_admin

def require_billing_admin
  head :forbidden unless current_account&.role_in(current_organization) == "owner"
end
```

Worth separating the two questions in whatever rule you write: reading which
plan you are on and changing the card are rarely the same permission.

## What you can ask

sparrow_pay does not wrap Pay. It makes the organization the customer and then
gets out of the way, so everything about subscriptions, charges and payment
methods is Pay's own API:

```ruby
organization.payment_processor.subscribed?
organization.payment_processor.subscription
organization.payment_processor.charges
```

See [Pay's documentation](https://github.com/pay-rails/pay) for the rest.

sparrow_pay adds exactly three things on top: the organization is the customer
rather than a person, `billing_email` follows ownership rather than whoever set
the subscription up, and the control panel stores your processor's API keys
without you editing a file.

**The control panel does that and nothing else.** Choose a processor, enter its
keys. It holds no settings of its own beyond that, on purpose: a setting that
lives in two places is a setting that will disagree with itself, and everything
about how you bill is Pay's or yours.

## Three things this deliberately leaves to you

**Your products.** Plans, prices, names, intervals and currencies are configured
in Stripe or Paddle, where you already configured them. This gem does not
restate them in Ruby.

**What a plan unlocks.** Your processor has never heard of `api_access`. Read
the subscription from Pay and compare against your own constants:

```ruby
GROWTH = "pri_01j8xyz"   # your constant, your name for it

def show
  subscription = organization.payment_processor.subscription
  head :payment_required unless subscription&.active?
  @reports = Report.all if subscription&.processor_plan == GROWTH
end
```

**What a failed payment costs somebody.** A failed payment reports `past_due`,
and that is all it does. Some applications cut access the hour a renewal is
declined; some carry a customer for a fortnight while their finance department
moves. Write the rule you want:

Read the state from Pay's subscription and write the rule you want. sparrow_pay
has no opinion about it and stores no status of its own.

## There are no billing pages

This gem mounts nothing and serves nothing. A billing page carries your plan
names, your copy and your upgrade argument, and a page shipped from a gem is a
page you would replace on the first afternoon.

Build it from Pay's API on `organization.payment_processor`, and guard it with
your own rule — see the note above about who may see billing. To send somebody
to the processor, use Pay's own helpers on the customer; this gem does not wrap
them, because wrapping them is where a checkout starts taking its price from a
form parameter.

Webhooks need nothing mounted and nothing configured here: Pay receives and
verifies them. **sparrow_pay emits no notification of its own** — subscribe to
Pay's hooks if you want to react to a status change. The engine sends no mail
itself; what a customer should be told is your copy and your decision.

## Known gaps

- No usage, metered or per-seat quantity billing.
- No invoicing, tax or coupons — those are the processor's.
- No dunning email; the notification above is where yours would start.

## Further reading

How any of this works and why it is shaped this way — the processor boundary,
what happens when a webhook arrives twice, how plan lookups degrade — is at
this README.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
