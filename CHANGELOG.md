# Changelog

Notable changes to SparrowKit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html) with all four gems
released in lockstep at one version.

## Unreleased

## 1.5.4 - 2026-09-15

### Fixed

- `Envelope::Address#to_s` built its `"name <email>"` string by hand
  interpolation, so a display name containing a comma — a legal business
  name like `"Acme, Inc."` — produced an unquoted string that Postmark's and
  SES's own address parsers read as a list of two addresses, rejecting the
  first for having no `@`. The raw-MIME transports (SES's body, SMTP) never
  hit this, since they re-serialise the original `Mail::Message`, whose own
  header writer already quotes correctly; only the JSON adapters, and SES's
  separate `from_email_address` parameter, took `Address#to_s` directly.
  Fixed by building through `Mail::Address` instead of a second hand-rolled
  implementation of the same RFC 5322 quoting rule.

## 1.5.3 - 2026-09-14

### Added

- The Postmark adapter accepts an opt-in `subscription_management` setting.
  Set to `"None"` on a stream, it turns off Postmark's own "Unsubscribe"
  footer — a sensible default for an application with no unsubscribe handling
  of its own, but a second "Unsubscribe" line stacked beneath a host's own for
  one that already ships a footer link, `List-Unsubscribe` headers and
  suppression driven by bounce and complaint webhooks. Omitted entirely
  unless a stream sets it, so existing applications are unaffected.

## 1.5.2 - 2026-09-14

### Added

- `sparrowkit:install` now creates `config/credentials/development.yml.enc`
  and `production.yml.enc`, and their key files, for any target that does not
  already have them -- the same thing `bin/rails credentials:edit
  --environment NAME` would create on a first run. A fresh install now has
  something the console can open instead of failing "credentials are
  unavailable" before anybody has typed a secret.

### Fixed

- A first, session-less visit to `/sparrowkit/` failed with "Choose a
  supported credential target" instead of opening the console. It now
  redirects to the Development target by default; an explicit invalid target,
  or a stale one left over in the session, still fails safely rather than
  silently opening the wrong store.

## 1.5.1 - 2026-09-13

### Fixed

- The development console's header could wrap onto two lines well before the
  window got narrow: a "Credentials" label sat next to a nav already labelled
  Development and Production, and the gaps between nav sections were wider
  than they needed to be. Removed the redundant label and tightened the
  spacing so the header holds to one line at common window widths.

### Changed

- The colour-theme switcher moved from the header to the footer, right-aligned
  next to the copyright line, freeing header space for the credential-target
  tabs and module navigation.

## 1.5.0 - 2026-09-11

### Added

- The development-only SparrowKit console can now target separate Development
  and Production encrypted credential stores. Target selection is server-side
  allow-listed and fails closed, so an invalid target cannot read or write a
  credential store.
- Production-target console use permits configuration saves only. Provider,
  test, sign-in, delivery, payment, webhook, and other execution actions are
  unavailable in the interface and rejected by the server.

## 1.4.0 - 2026-09-08

### Fixed

- An organization can be made into a customer at all. Pay reads the customer's
  address by delegating `email` to the billable model, which
  `SparrowAuth::Organization` did not define, so the first attempt to create a
  customer raised `NoMethodError` on every processor -- Stripe, Paddle, Lemon
  Squeezy and Braintree alike. `SparrowPay::Billable` now defines `email`,
  returning `billing_email`.
- `billing_email` falls back to the earliest **membership** rather than the
  first row of `accounts`, which is ordered by account id -- the order people
  signed up in, not the order they joined. In an organization whose roles are
  not called "owner", a colleague with an older account joining later quietly
  took over the receipts.

### Added

- The processor's copy of the billing contact is kept current. A seat changing
  hands, the billing account correcting its own address, and a rename each
  enqueue Pay's `CustomerSyncJob`; none of the three is an update to the
  organization row, so the callbacks are on memberships and accounts rather
  than on the billable model, and Pay's own sync -- which watches for an email
  column an organization does not have -- never fired at all.
- `SparrowPay::Billable#sync_billing_details`, for an application that moves
  the receipts by a rule of its own. It syncs only customers that already exist
  at the processor: Pay's update opens one when there is no processor id, so an
  unguarded sync would open an account at the processor for every organization
  on the system.

### Removed

- `SparrowPay::Billable#pay_customer_email`. Pay never asked for it: it reads
  `owner.email`, which is why nothing was reaching the processor. The README,
  AGENTS.md and the control panel's guide all taught it as the hook Pay reads;
  they now teach `email`.

## 1.3.0 - 2026-09-02

### Changed

- The control panel's second mail stream is `broadcast`, which is what the
  sparrow_mail README, the Postmark adapter and the conformance suite already
  called it. The panel wrote `marketing:` to credentials, so a developer who
  configured two providers there and then set the header the README showed
  them got "unknown stream :broadcast" from the fail-closed stream lookup. A
  `marketing:` key already in credentials is read as the broadcast stream and
  rewritten under its new name the next time the Mail panel is saved.
- The panel's guide for agents no longer tells them to pass `stream:` to the
  `mail` call, which set a header nothing read. It shows the
  `X-Sparrow-Stream` header instead, as the README does.

### Added

- The control panel's test email covers both streams. With two providers
  configured it offers a choice -- transactional, broadcast, or one message
  on each, which is the default -- and reports each send on its own, so a
  broadcast that fails beside a transactional that succeeds is reported as
  exactly that. Each message names its stream in the subject and body, and
  the ten-second hold between tests is kept per stream. With one provider
  nothing changes.
- `SparrowUi::Console::Settings.move`, which moves one subtree of a module's
  settings to another key with its secrets intact. A panel only ever sees
  secrets masked, so it could not rename a section through `write` without
  losing the API key inside it. The mail panel uses it to carry an old
  `marketing:` key across to `broadcast:`.

## 1.2.0 - 2026-09-02

### Added

- The control panel asks for everything Amazon SES needs. The region is a
  dropdown of the regions where SES is offered, read from the AWS SDK's own
  partition data rather than a list kept here, and the access key ID and
  secret access key have boxes of their own, with a hint saying when leaving
  them blank is right: only when the SDK already has credentials from the
  environment, a profile or an instance role. Before, the panel offered one
  text box for the region and nowhere to put a key.
- Adapters can say more about their settings. `Adapters::Base` gains
  `fallback_settings` (needed, but found elsewhere when not given),
  `optional_settings` (not needed), `setting_choices(name)` and
  `setting_hint(name)`. The panel renders a dropdown for a setting with
  choices, marks optional ones and only those, and shows an adapter's hint
  beside its box. An adapter that declares none of them renders exactly as
  before. The panel still keeps no list of providers.
- A send through SES with no credentials anywhere now raises
  `ConfigurationError` naming both places a key can go, instead of the SDK's
  exception class and nothing else.

### Fixed

- The first save of a control panel section no longer writes keys the panel
  meant to leave out as `key:` with nothing after the colon. `nil` now means
  "not this key" whether or not the section already existed.

## 1.1.0 - 2026-08-27

### Added

- `SparrowMail::RetryableDeliveryJob`, an opt-in `ActionMailer::MailDeliveryJob`
  for mail sent through `deliver_later` where a retried duplicate is an
  acceptable risk. It retries `RateLimitError`, `ProviderError` and
  `NetworkError` -- the categories where sending again has a chance of
  working -- and leaves `AuthenticationError` and `InvalidRecipientError`
  alone, since retrying either only delays a failure that was never going to
  resolve. A mailer opts in with `self.delivery_job =
  SparrowMail::RetryableDeliveryJob`; the gem's own send stays exactly as
  retry-free as it always was.
- The Postmark adapter now documents and accepts an optional `account_token`
  setting, reserved for account-level Postmark operations this gem does not
  yet make. It is not required and does not appear in the control panel --
  the same treatment the SES adapter already gives `access_key_id` and
  `secret_access_key`.

### Fixed

- `SparrowMail::DeliveryMethod`'s doc comment claimed ActiveJob retries
  failed jobs by default and pointed at a README section, "deliver_later and
  retries", that did not exist. Neither was true: retrying depends on the
  queue backend, and the section is now written, under "Retrying through
  deliver_later".

## 1.0.2 - 2026-08-25

### Fixed

- The install instructions did not work. Every README showed
  `gem "sparrow_auth"`, which cannot resolve: the gems are not on RubyGems, and
  they pin each other to an exact version, so Bundler looked on rubygems.org
  for a version that is not there. All of them now show one `git` block with
  `glob: "gems/*/*.gemspec"`, which also lets a single module be installed on
  its own -- `sparrow_pay` alone resolves and locks all three.
- `sparrow_auth`'s README gave no Gemfile step at all, opening on the rake task.
- A shipped `config/routes.rb` and a migration comment still described
  `rails generate sparrowkit:screens` and `SparrowAuth::Role`, both removed.

### Added

- The documentation check reads what the gemspecs package, rather than a list
  of directories, so a file in a directory nobody thought of is covered the
  moment it ships. It also verifies the install snippets carry the git source
  and pin the version being released.
- The docs record that `sparrowkit:install` comes from `sparrow_ui`, and name
  the per-module install tasks for anyone not taking the control panel.

## 1.0.1 - 2026-08-24

### Fixed

- The control panels no longer tell you to call `require_organization!`, which
  does not exist. Both the payments and authentication panels taught it.
- The installer's closing step, a test-helper error and the authentication
  panel no longer point at `rails generate sparrowkit:screens`, a generator
  that does not exist. They point at Rodauth's own `/auth/login` instead.
- `sparrow_auth`'s README no longer claims API tokens, ready-made admin pages,
  generators that "write the tedious parts", or theming through a layout
  directory the gem does not ship.
- Both READMEs said Ruby 3.1 and Rails 7.1; the gems require 3.2 and 8.1.

### Changed

- Both linters target Ruby 3.2, matching the gemspecs. `keyword_init: true` is
  redundant there and has been removed from the Structs that carried it.

### Added

- The processor's copy of the billing contact is kept current. A seat changing
  hands, the billing account correcting its own address, and a rename each
  enqueue Pay's `CustomerSyncJob`; none of the three is an update to the
  organization row, so the callbacks are on memberships and accounts rather
  than on the billable model, and Pay's own sync -- which watches for an email
  column an organization does not have -- never fired at all.
- `SparrowPay::Billable#sync_billing_details`, for an application that moves
  the receipts by a rule of its own. It syncs only customers that already exist
  at the processor: Pay's update opens one when there is no processor id, so an
  unguarded sync would open an account at the processor for every organization
  on the system.

### Removed

- `SparrowAuth::InvalidApiToken`, an error class with no feature behind it and
  nothing that raised it.

### Internal

- The documentation check reads console views and shipped Ruby comments, not
  only Markdown, and verifies each README's stated Ruby and Rails versions
  against its gemspec. Every fault above predates that check and none of them
  were visible to it.
