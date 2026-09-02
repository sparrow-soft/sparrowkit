# Changelog

Notable changes to SparrowKit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html) with all four gems
released in lockstep at one version.

## Unreleased

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

### Removed

- `SparrowAuth::InvalidApiToken`, an error class with no feature behind it and
  nothing that raised it.

### Internal

- The documentation check reads console views and shipped Ruby comments, not
  only Markdown, and verifies each README's stated Ruby and Rails versions
  against its gemspec. Every fault above predates that check and none of them
  were visible to it.
