# SparrowKit

The parts of a Rails application that are the same every time — signing
people in, sending email, taking money — already written, so the part that is
not the same every time is the part you write.

Four pieces. You can use one of them or all of them.

| | |
|---|---|
| [`sparrow_mail`](gems/sparrow_mail) | Sending email, through whichever provider you like. Swap providers by changing one setting. |
| [`sparrow_auth`](gems/sparrow_auth) | Accounts and signing in: passkeys, a code sent by email, Google or Apple, and passwords if you want them. Shared accounts for teams, and keeping one customer's records away from another's. |
| [`sparrow_pay`](gems/sparrow_pay) | Subscriptions, on top of the well-established [Pay](https://github.com/pay-rails/pay) gem, billing the team rather than the person. |
| [`sparrow_ui`](gems/sparrow_ui) | The control panel you set all of it up in. Runs on your own machine only, and never in production. |

One command installs whichever of them you want.

## Installing it

Put whichever modules you want in the `Gemfile`, with `sparrow_ui` in the
development group — it is the control panel, and it must never be in
production:

```ruby
# Gemfile
#
# Not on RubyGems yet, so the gems come from the repository. One `git` block for
# all four: Bundler fetches the repository once, and `tag:` pins you to a
# release rather than to whatever `main` holds today.
#
# Comment out the modules you do not want. What you cannot do is take one on its
# own from RubyGems -- sparrow_auth depends on exactly this version of
# sparrow_mail, and sparrow_pay on exactly this version of sparrow_auth, so
# every gem in the chain has to come from the same source.
git "https://github.com/sparrow-soft/sparrowkit.git", tag: "v1.0.1", glob: "gems/*/*.gemspec" do
  gem "sparrow_auth"   # passkeys, organizations, invitations
  gem "sparrow_mail"   # transactional and marketing email
  gem "sparrow_pay"    # subscription billing

  group :development do
    gem "sparrow_ui"   # the control panel at /sparrowkit; never in production
  end
end
```

Then one command:

```bash
bin/rails sparrowkit:install
```

That mounts each engine in your routes, mounts the control panel at
`/sparrowkit`, copies each module's database tables in and applies them, and
tells you what it changed. It is safe to run again — a second run adds nothing
and says so.

**`sparrowkit:install` comes from `sparrow_ui`.** If you are not taking the
control panel, use the module's own task instead — `bin/rails
sparrow_mail:install`, `sparrow_auth:install` or `sparrow_pay:install`. Each
does the same work for its own module.

Installing one module on its own works the same way:

```bash
bin/rails sparrow_mail:install
```

**It runs only its own migrations.** `bin/rails db:migrate` means "apply every
pending change in this application", so on an existing app it would also run
whatever migration you were halfway through writing. The installer runs the
ones it copied and no others, and tells you if you have any of your own left
pending.

Then start the server and open **http://localhost:3000/sparrowkit**. Every API
key and setting is entered there; it writes them to Rails encrypted credentials
under one top-level key per gem, which each module reads at boot. There is no
settings file to edit and no environment variables to set.

## What is deliberately not in here

Nothing about any particular business. No wine, no restaurants, no legal
matters, no social posts. If a feature exists because exactly one application
needed it, it lives in that application and not in these gems.

That matters to you rather than to us: there is nothing of somebody else's
business to work around, strip out, or accidentally inherit.

## Layout

```
gems/sparrow_mail    email delivery           (depends on nothing)
gems/sparrow_auth    authentication           (depends on sparrow_mail)
gems/sparrow_pay     billing                  (depends on sparrow_auth)
gems/sparrow_ui      developer console theme  (depends on nothing; dev-only)
```

One repository, many separately-installable gems, one version, one tag, one
changelog — the same way Rails itself is organised. Each gem being separately
installable keeps the boundaries honest and lets each one be tested on its
own; it is not a combination we support you assembling by hand.

## Reading the code

Every gem is ordinary Rails — models, controllers, views, all where you would
expect them. Read it, change it, fork it. If you fix something, a pull request
is welcome.

## Documentation

What each module does and how to use it is in its own README, under `gems/`.
Beyond that, the code is the documentation — and the comments in it explain
why a rule is shaped the way it is, not merely what it does.

## Security

The security model — what `sparrow_auth` defends against, how each control
works, and, the part worth reading, where each one stops — is in
[`gems/sparrow_auth/README.md`](gems/sparrow_auth/README.md) and
[`SECURITY.md`](SECURITY.md).

Claims there are backed by the test suite; the ones easiest to get subtly wrong
are additionally mutation tested, meaning the guard was deliberately broken to
confirm a test goes red. A test that passes whether or not the protection exists
is worse than no test, because it is believed.

**Found a security problem?** Report it to **humans@sparrowsoft.co** rather than
opening a public issue. Reports are acknowledged within two working days. See
[`SECURITY.md`](SECURITY.md).

## Licence

MIT. See [LICENSE.txt](LICENSE.txt).
