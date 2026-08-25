# frozen_string_literal: true

require_relative "lib/sparrow_mail/version"

Gem::Specification.new do |spec|
  spec.name = "sparrow_mail"
  spec.version = SparrowMail::VERSION
  spec.authors = ["SparrowSoft"]
  spec.email = ["humans@sparrowsoft.co"]

  spec.summary = "Provider-agnostic ActionMailer delivery layer."
  spec.description = <<~DESC.tr("\n", " ").strip
    An ActionMailer delivery layer with a provider adapter interface. Switching
    email providers is a configuration change, never a code change. The core
    enforces two inviolable rules regardless of adapter: message bodies are
    never logged, and a send is never retried. Ships adapters for SendLayer,
    Postmark, SendGrid, Mailgun, Amazon SES, SMTP, and a test mode, plus the
    conformance suite every adapter must pass.
  DESC
  spec.homepage = "https://github.com/sparrow-soft/sparrowkit"
  # Proprietary and source-available; see LICENSE.txt. SPDX has no generic
  # identifier for this, and LicenseRef-* is its documented escape hatch.
  spec.license = "MIT"
  # 3.2, not 3.1. Ruby 3.1 reached end of life in March 2025, so it receives no
  # security patches -- and a floor that admits an unpatched interpreter is a
  # floor that says this product runs safely there.
  spec.required_ruby_version = ">= 3.2"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/gems/sparrow_mail"
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  # An accident guard, not a security control.
  #
  # These gems are proprietary and are sold as a tarball. `gem push` refuses any
  # host but this one, and this one is not a gem server -- so the reflex
  # `gem build && gem push`, carried over from a public project, fails
  # immediately instead of putting the source on a public index. RubyGems only
  # allows an unpublish within 30 minutes, and never a re-use of the name.
  #
  # It also blocks GitHub Packages' Ruby registry, which is reached the same way
  # (`gem push --host https://rubygems.pkg.github.com/...`).
  #
  # Anyone who can edit this file can delete this line, which is the point at
  # which it stops being a guard. What actually keeps the source private is that
  # the repository is private and no workflow publishes anything.
  spec.metadata["allowed_push_host"] = "https://sparrowkit.co/not-a-gem-server"

  # console/ and config/ are the control panel, and they have to ship: the
  # panel is loaded from an installed gem on a developer's machine, and a
  # missing view is a 500 on the one page that exists to make setup easy.
  spec.files = Dir[
    # `lib/**/*` and not `lib/**/*.rb`.
    #
    # The narrower glob dropped every .rake and every .tt under lib -- which is
    # to say the install tasks and every generator template. A built .gem
    # therefore installed, loaded, and then raised on the first
    # `rails generate`, with nothing in the packaging step saying anything was
    # missing. Nothing here is loaded from lib by wildcard, so taking the whole
    # tree costs a few kilobytes and removes a class of silent omission.
    "lib/**/*",
    "console/**/*",
    "config/**/*",
    "README.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  # The only hard runtime dependency. `mail` gives us message parsing and the
  # SMTP transport; ActionMailer is detected at runtime via a Railtie so the gem
  # is usable outside Rails. See README.md, "Why not depend on ActionMailer".
  spec.add_dependency "mail", "~> 2.8"

  # Declared, because it stopped being free. base64 was a default gem until Ruby
  # 3.4, where it became bundled -- and `require "base64"` in a gem that never
  # named it is a warning today and a LoadError on the day the platform drops
  # it. Two files here require it: the envelope and the Mailgun adapter.
  spec.add_dependency "base64", "~> 0.2"

  # AND NO RAILS, DELIBERATELY -- which is worth stating because this gem ships
  # a railtie, a console engine and a generator, and a reader who finds those
  # will reasonably think the dependency was forgotten.
  #
  # The delivery layer is `mail` and nothing else. Every Rails-facing file is
  # loaded behind `defined?(Rails)` and does nothing without it, which is what
  # lets this gem's suite run with no Rails in it at all -- and a delivery layer
  # that can only be tested inside a Rails application is a delivery layer
  # nobody tests in isolation.
  #
  # Declaring Rails here would not add anything; it would take something away, and
  # would make every application carrying this gem carry a framework it may have
  # no other use for.

  # Optional, adapter-specific. Loaded lazily by the adapter that needs it and
  # deliberately NOT a runtime dependency, so an app that uses Postmark does not
  # install the AWS SDK:
  #
  #   Amazon SES adapter -> aws-sdk-sesv2
end
