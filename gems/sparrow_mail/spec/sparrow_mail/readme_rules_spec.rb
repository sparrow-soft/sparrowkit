# frozen_string_literal: true

# The two rules that govern this gem have to be stated where people read.
#
# They used to be checked in the install generator's initializer template,
# "since this file is what most people read". That template is gone -- it
# configured the same settings as the control panel and, being evaluated after
# credentials, silently overwrote them -- so the check moves to what people
# read now.
#
# Kept as a check rather than a review because these are the two claims the
# gem's design is built around. If either stops being stated, either the
# documentation rotted or the rule did, and both are worth stopping for.
RSpec.describe "the README's inviolable rules" do
  let(:readme) do
    File.read(File.expand_path("../../README.md", __dir__), encoding: "UTF-8")
  end

  it "states that message bodies are never logged" do
    expect(readme).to match(/never logged/i)
  end

  it "states that a send is never retried" do
    expect(readme).to match(/never retried/i)
  end

  # The other half of what the old template guarded: a developer has to be able
  # to find out that a provider exists at all.
  #
  # A weaker check than the one it replaces, and deliberately so. The control
  # panel builds its provider list from SparrowMail.registry at render time, so
  # it cannot fall behind the way a hand-written file did -- see the request
  # spec that renders every registered provider's fields. This only asks that
  # the README does not silently omit one.
  it "names every adapter that ships with the gem" do
    missing = SparrowMail::BUILT_IN_ADAPTERS.reject { |name, (_path, _const, display)|
      readme.downcase.include?(name.to_s.downcase) || readme.include?(display)
    }.keys

    expect(missing).to be_empty,
      "the README does not mention: #{missing.join(", ")}"
  end
end
