# frozen_string_literal: true

require_relative "lib/sparrow_ui/version"

Gem::Specification.new do |spec|
  spec.name = "sparrow_ui"
  spec.version = SparrowUi::VERSION
  spec.authors = ["SparrowSoft"]
  spec.email = ["humans@sparrowsoft.co"]

  spec.summary = "SparrowKit's developer console theme and components."
  spec.description = <<~DESC.tr("\n", " ").strip
    A Tailwind stylesheet and ERB components for SparrowKit's developer-facing
    surfaces: the configuration console, demos, smoke harnesses and
    documentation. Development tooling, not a production dependency, and not a
    component library for a customer's own application.
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
  spec.metadata["source_code_uri"] = "#{spec.homepage}/tree/main/gems/sparrow_ui"
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

  # The COMPILED stylesheet ships (it lives under app/assets); tailwind/ and
  # package.json do not. A host installs a gem, not a build toolchain.
  #
  # config/ has to be here too. Rails::Engine reads config/routes.rb off the
  # gem's own root, so leaving it out ships an engine that mounts cleanly and
  # then resolves nothing -- a failure with no error message anywhere.
  spec.files = Dir[
    "app/**/*",
    "config/**/*",
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

  # railties for the engine, actionview for the partials, actionpack for the
  # console's controller and the Rack middleware that gates it. Deliberately
  # not the `rails` metagem: this ships views, a stylesheet and one gated page,
  # and has no business dragging in ActiveRecord or ActionMailer.
  #
  # 8.1 for the same reason as the other gems; see the fuller note in
  # sparrow_auth's gemspec.
  spec.add_dependency "railties", ">= 8.1", "< 9"
  spec.add_dependency "actionview", ">= 8.1", "< 9"
  spec.add_dependency "actionpack", ">= 8.1", "< 9"
end
