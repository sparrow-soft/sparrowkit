# frozen_string_literal: true

require_relative "lib/sparrow_auth/version"

Gem::Specification.new do |spec|
  spec.name = "sparrow_auth"
  spec.version = SparrowAuth::VERSION
  spec.authors = ["SparrowSoft"]
  spec.email = ["humans@sparrowsoft.co"]

  spec.summary = "Mountable Rails authentication engine on Rodauth."
  spec.description = <<~DESC.tr("\n", " ").strip
    A mountable Rails engine providing the SparrowKit auth ladder (passkeys,
    email OTP, social, passwords last), mandatory email verification,
    revocable DB-backed sessions and API tokens, organizations and memberships,
    roles as permission sets, and row-based multi-tenancy helpers.
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
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/gems/sparrow_auth"
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

  spec.files = Dir[
    "app/**/*",
    "config/**/*",
    "console/**/*",
    "db/**/*",
    # `lib/**/*` and not `lib/**/*.rb`.
    #
    # The narrower glob dropped every .rake and every .tt under lib -- which is
    # to say the install tasks and every generator template. A built .gem
    # therefore installed, loaded, and then raised on the first
    # `rails generate`, with nothing in the packaging step saying anything was
    # missing. Nothing here is loaded from lib by wildcard, so taking the whole
    # tree costs a few kilobytes and removes a class of silent omission.
    "lib/**/*",
    "README.md",
    "LICENSE.txt"
  ]
  spec.require_paths = ["lib"]

  # Dependency chain: sparrow_mail <- sparrow_auth <- sparrow_pay.
  # Pinned exactly because the gems release in lockstep from one VERSION file.
  spec.add_dependency "sparrow_mail", SparrowAuth::VERSION

  # 8.1, because everything older is either past end of life or nearly there:
  # 7.1 ended 2025-10-01, 7.2 ended 2026-08-09, and 8.0 ends 2026-11-07. An
  # authentication product has no business admitting a Rails that Rails itself
  # has stopped patching, and shipping a new release against one six weeks from
  # that date is the same mistake with a delay on it.
  spec.add_dependency "rails", ">= 8.1", "< 9"

  # Rodauth owns the crypto, the ceremony handling and the flow security. This
  # gem is configuration, the organization model, the resolver and glue, and
  # deliberately reimplements none of it.
  spec.add_dependency "rodauth-rails", "~> 2.0"

  # Rodauth is Sequel-based. This shares the ActiveRecord connection rather than
  # opening a second pool, so an application has one database configuration and
  # one connection budget, not two that can disagree.
  spec.add_dependency "sequel-activerecord_connection", "~> 2.0"

  # Rodauth hashes tokens at rest with these.
  spec.add_dependency "bcrypt", "~> 3.1"

  # Roda's render plugin, which the Rodauth app runs through, needs Tilt. It is
  # not pulled in transitively, and its absence surfaces as a LoadError on the
  # first request rather than at boot.
  spec.add_dependency "tilt", "~> 2.0"

  # Passkeys. Rodauth's webauthn features delegate every piece of the ceremony
  # — challenge generation, attestation and assertion verification, signature
  # checking — to this. Three applications in this portfolio each implemented
  # that themselves, three different ways; none of that code survives here.
  spec.add_dependency "webauthn", "~> 3.0"
end
