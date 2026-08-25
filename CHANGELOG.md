# Changelog

Notable changes to SparrowKit are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project uses
[semantic versioning](https://semver.org/spec/v2.0.0.html) with all four gems
released in lockstep at one version.

## Unreleased

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
