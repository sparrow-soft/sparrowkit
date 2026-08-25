# frozen_string_literal: true

require "rails_helper"

# Where the name on the From line comes from when nobody typed one into the
# mail settings.
#
# A product has one name. It is asked for once, on the control panel's front
# page, and every panel that needs it reads it from there — otherwise the
# passkey prompt says one thing, the From line says another, and both look
# right on the page that set them.
RSpec.describe "the name mail comes from" do
  around do |example|
    original = SparrowMail.configuration.default_from
    example.run
    SparrowMail.configuration.default_from = original
  end

  def with_product_name(name)
    allow(SparrowMail).to receive(:application_name).and_return(name)
  end

  # The address is the half nobody can guess. The name is the half everybody
  # has already given.
  it "puts the product's name in front of a bare address" do
    SparrowMail.configuration.default_from = "no-reply@acme.test"
    with_product_name("Acme Corp")

    expect(SparrowMail.configuration.default_from).to eq("Acme Corp <no-reply@acme.test>")
  end

  # A stored name IS the override — there is no separate flag, for the same
  # reason there is none on the passkey domain.
  it "leaves a mailbox that already names a sender alone" do
    SparrowMail.configuration.default_from = "Acme Support <help@acme.test>"
    with_product_name("Acme Corp")

    expect(SparrowMail.configuration.default_from).to eq("Acme Support <help@acme.test>")
  end

  it "leaves the address bare when no product name is set" do
    SparrowMail.configuration.default_from = "no-reply@acme.test"
    with_product_name("")

    expect(SparrowMail.configuration.default_from).to eq("no-reply@acme.test")
  end

  # Unquoted, `Acme, Inc <a@b>` is a comma-separated list of two addresses and
  # the mail goes to somebody called "Acme".
  it "quotes a name carrying anything RFC 5322 treats as punctuation" do
    SparrowMail.configuration.default_from = "no-reply@acme.test"
    with_product_name("Acme, Inc.")

    expect(SparrowMail.configuration.default_from).to eq('"Acme, Inc." <no-reply@acme.test>')
  end

  it "stays nil when there is no address, because a name alone is not a sender" do
    SparrowMail.configuration.default_from = nil
    with_product_name("Acme Corp")

    expect(SparrowMail.configuration.default_from).to be_nil
  end
end
