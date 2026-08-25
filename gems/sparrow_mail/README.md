# sparrow_mail

Sending email from a Rails application, without your code knowing or caring
who actually sends it.

You write mailers the ordinary Rails way. This gem handles getting them out of
the door. Moving from one email company to another — SendLayer to Postmark,
Postmark to Amazon — means changing one setting and pasting in a new key.
Nothing in `app/mailers` ever names a company, so nothing in `app/mailers` has
to change.

Six services work out of the box: SendLayer, Postmark, SendGrid, Mailgun,
Amazon SES and plain SMTP. There is also a test mode that pretends to send, so
your test suite never emails anybody by accident.

Each of those is called an **adapter** — the small piece of code that knows how
to talk to one company. You pick one by name (`adapter: :postmark`) and never
think about it again.

Part of [SparrowKit](../../README.md). Needs Ruby 3.2 or newer.

---

## Two rules you cannot switch off

**Message bodies are never logged.** Transactional mail carries live sign-in
codes and invitation tokens, and a log aggregator is a place those outlive their
expiry, in a system with different access rules than the application that issued
them. Adapters are never handed a logger at all, so a new one cannot leak a body
by forgetting a convention. Provider error messages are scrubbed too, because
providers routinely quote the message they rejected back at you.

**A send is never retried.** A send that timed out may well have arrived.
Sending it again puts a second copy of a one-time code in somebody's inbox and
invalidates the first. The adapter is called exactly once.

Both matter to you when something fails: you will get an error rather than a
silent second attempt, and it is yours to decide what happens next.

## Install

```ruby
# Gemfile
#
# Not on RubyGems yet, and the four gems pin each other to an exact version, so
# they all come from the repository in one `git` block. Comment out what you do
# not want.
git "https://github.com/sparrow-soft/sparrowkit.git", tag: "v1.0.1", glob: "gems/*/*.gemspec" do
  gem "sparrow_mail"
end
```

```bash
bin/rails sparrow_mail:install
```

That points ActionMailer at this gem and mounts the SparrowKit control panel. It
writes no settings file and creates no tables.

Then choose a provider and enter your API key at
`http://localhost:3000/sparrowkit/mail`. It writes to `sparrow_mail:` in your
Rails encrypted credentials, which this gem reads at boot — or edit the same
file by hand:

```yaml
sparrow_mail:
  default_from: Acme <hello@acme.test>
  transactional:
    adapter: postmark
    api_key: ...
```

There is deliberately no `config/initializers/sparrow_mail.rb`. Initializers are
evaluated *after* credentials are read, so a generated one would silently
overwrite whatever you had just saved in the panel.

In the test environment the test adapter is selected automatically unless you
say otherwise, so a suite cannot post to a real provider by accident.

In development, with no provider chosen yet, the **preview** adapter is
selected the same way: every message is written to `tmp/sparrowkit-mail` as a
`.eml` file you can open, and the control panel lists them. It is a floor, not
a choice — the panel goes on telling you no provider is configured, because
none is and nobody is receiving anything. Choose one before you deploy.

## Configuring

| Setting | Environment variable | Meaning |
|---|---|---|
| `adapter` | `SPARROW_MAIL_ADAPTER` | Which provider. Required. |
| `sandbox` | `SPARROW_MAIL_SANDBOX` | Send nothing to real inboxes. |
| `default_from` | `SPARROW_MAIL_DEFAULT_FROM` | Used when a message has no `From` of its own. Store the address alone and mail goes out from your product's name, taken from the control panel's home page — `Acme Corp <hello@acme.test>`. Name a sender here and that name is used instead. |
| `settings` | — | Provider credentials. |
| `logger` | — | Defaults to `Rails.logger`. `nil` disables logging. |

Every setting has an environment-variable equivalent, which is the point:
changing provider in a deployed application is a new value for
`SPARROW_MAIL_ADAPTER` and a new credential, not a deploy of changed code.
Values set in code win over the environment.

## Sending

Through ActionMailer, as normal — nothing about your mailers changes. Or
directly:

```ruby
SparrowMail.deliver!(mail)   # raises SparrowMail::DeliveryError on failure
SparrowMail.deliver(mail)    # returns a Result carrying the failure
```

`deliver!` is what ActionMailer calls. `deliver` is for callers that treat a
failed send as a value rather than an exception — a job recording an outcome, a
bulk send that must not stop at one bad address:

```ruby
result = SparrowMail.deliver(mail)

unless result.success?
  case result.category
  when :invalid_recipient then subscriber.mark_undeliverable!
  when :rate_limited      then DeferredMailJob.set(wait: 5.minutes).perform_later(...)
  else                         Honeybadger.notify(result.error)
  end
end
```

`success?` and `delivered?` are different: a message withheld in sandbox mode is
a success that was not delivered.

## When sending fails

Every failure lands in exactly one of these categories. The vocabulary is this
gem's rather than any provider's, which is what lets one `rescue` keep meaning
the same thing after you switch providers.

| Class | `category` | What happened |
|---|---|---|
| `AuthenticationError` | `:auth` | Credentials rejected. Needs a human. |
| `InvalidRecipientError` | `:invalid_recipient` | Address malformed, suppressed, or bouncing. |
| `RateLimitError` | `:rate_limited` | Throttled. |
| `ProviderError` | `:provider_down` | The provider says it broke. |
| `NetworkError` | `:provider_down` | No usable answer: refused, TLS failure, timeout. |
| `UnknownError` | `:unknown` | Could not be classified — kept separate so "we don't know" never reads as "they're down". |

All of them descend from `SparrowMail::DeliveryError`.
`SparrowMail::ConfigurationError` does not: a message with no recipient, or an
adapter with no API key, is a bug in your application rather than a failed send,
so it raises even from `deliver`.

Errors carry `adapter`, `status_code`, `provider_code`, `provider_message` and
`recipients`, and `#to_h` gives you all of it in a shape that is safe to log.

## Sandbox mode

`config.sandbox = true` means nothing reaches a real inbox and every message is
recorded in `SparrowMail.deliveries` for inspection. This is what replaces
Mailtrap.

Where the provider has a sandbox of its own it is used, so the request really
goes out and the whole path is exercised. Where it does not, nothing is
contacted. Either way `result.sandbox?` is true and the message is recorded.

## Bulk mail and transactional mail

These must not share a sending reputation. If your newsletter collects spam
complaints, that should not decide whether anybody receives their sign-in code —
and some providers will suspend an account for pushing bulk mail through a
transactional identity.

A message says which it is, and defaults to transactional:

```ruby
class NewsletterMailer < ApplicationMailer
  def weekly_digest(subscriber)
    headers["X-Sparrow-Stream"] = "broadcast"

    mail(to: subscriber.email, subject: "This week")
  end
end
```

Postmark and Amazon SES separate the two themselves and need no configuration.
Providers that have no such notion need a different sending identity instead — a
different domain, account, or provider — which is one line of configuration.

## Testing your own application

```ruby
SparrowMail.configure { |config| config.adapter = :test }

SparrowMail.deliveries.last.subject
SparrowMail.deliveries.last.to.map(&:email)
SparrowMail.deliveries.last.text_body
SparrowMail.deliveries.clear
```

Deliveries are already-parsed objects, so you assert on recipients and bodies
without re-parsing MIME yourself.

Test your failure handling too — a suite that only ever exercises the happy path
is how unhandled delivery errors reach production:

```ruby
SparrowMail::Adapters::Test.fail_with(
  SparrowMail::RateLimitError,
  status_code: 429,
  payload: {"message" => "Too many requests"}
)
```

Call `SparrowMail::Adapters::Test.reset!` between examples.

## Known gaps

- No batch send API; every adapter sends one message per request.
- No bounce or webhook handling. This gem puts mail on the wire; what comes back
  is your application's to deal with.

## Further reading

The full adapter table with each provider's settings, how to write an adapter
for a service not listed, tags and metadata, the detail of stream configuration,
and the reasoning behind the two rules above are covered above.

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
