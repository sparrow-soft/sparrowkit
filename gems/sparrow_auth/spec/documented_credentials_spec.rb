# frozen_string_literal: true

require "rails_helper"

# Every credentials key this gem's documentation names has to be one this gem
# actually reads.
#
# The install generator told people to write
# `Rails.application.credentials.sparrow_auth_otp` for a year. Nothing read
# that key. Following the instruction produced an application that booted, ran,
# and quietly derived its HMAC key instead of using the one somebody had gone
# to the trouble of setting -- and there is no symptom, because a derived key
# works perfectly until the day you needed yours.
#
# A commented line in a template is the worst place for this to go stale: no
# spec exercises it, no compiler reads it, and the person following it has no
# way to tell it is wrong. Hence a check rather than a review.
#
# `Rails.application.credentials.foo` and `credentials.foo`, but not
# `config.credentials.content_path` -- that is Rails' own configuration for
# where the file lives, not a key inside it.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
CREDENTIALS_READ = /(?<!config\.)\bcredentials\.(?!content_path|key_path)([a-z_][a-z0-9_]*)/

RSpec.describe "credentials keys named in the documentation" do
  # Everything a developer is handed or pointed at.
  def documents
    root = SparrowAuth::Engine.root

    {
      "the install generator's initializer template" =>
        root.join("lib/generators/sparrow_auth/install/templates/sparrow_auth.rb.tt"),
      "the README" => root.join("README.md")
    }.select { |_name, path| path.exist? }
  end

  it "names only the key this gem reads" do
    offenders = documents.flat_map { |name, path|
      path.read.scan(CREDENTIALS_READ).flatten.uniq
        .reject { |key| key.to_sym == SparrowAuth::CREDENTIALS_KEY }
        .map { |key| "#{name}: credentials.#{key}" }
    }

    expect(offenders).to be_empty, <<~MSG
      These name a credentials key nothing reads:

        #{offenders.join("\n  ")}

      sparrow_auth reads exactly one top-level key, #{SparrowAuth::CREDENTIALS_KEY}:, and
      the settings under it are named after the configuration options they set.
      Telling somebody to write a different key gives them an application that
      boots, runs, and ignores the value they set.
    MSG
  end

  it "is checking documents that exist, rather than passing because it found none" do
    # A guard that silently checks nothing is worse than no guard: this spec's
    # whole value is that somebody renaming or moving the template finds out.
    expect(documents.keys).to contain_exactly(
      "the install generator's initializer template",
      "the README"
    )
  end
end
