source "https://rubygems.org"

# Development loads every gem from source. Consuming applications pin a single
# released tag instead — see README.md, "Installing in an application".
gem "sparrow_mail", path: "gems/sparrow_mail"
gem "sparrow_auth", path: "gems/sparrow_auth"
gem "sparrow_pay", path: "gems/sparrow_pay"
gem "sparrow_ui", path: "gems/sparrow_ui"

gem "rake", "~> 13.0"

group :development, :test do
  gem "rspec", "~> 3.13"
  gem "standard", "~> 1.44"

  # Checks Gemfile.lock against the Ruby Advisory Database. Run with
  # `bundle exec rake audit`; CI runs it on every push and daily.
  gem "bundler-audit", "~> 0.9"

  # Here rather than `gem install`ed in CI, because Brakeman's findings depend
  # on its version: CI installed 8.0.6 while this machine had 7.1.0, and the
  # newer one raised a warning the older one had never mentioned. A security
  # tool that reports different things in two places is one nobody can act on.
  gem "brakeman", "~> 8.0"
  gem "webmock", "~> 3.24"

  # Exercised by sparrow_mail's ActionMailer integration specs. The gem itself
  # depends only on `mail`; see docs in gems/sparrow_mail/README.md.
  gem "actionmailer", ">= 7.0"

  # Optional adapter dependency. Required only by the Amazon SES adapter, which
  # loads it lazily. CI installs it so the SES adapter runs the conformance suite.
  gem "aws-sdk-sesv2", "~> 1.60"
end
