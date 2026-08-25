# frozen_string_literal: true

require "rails_helper"

# The one setting a later change cannot undo.
#
# A passkey is bound to a relying-party id permanently. Get it wrong and the
# repair is not an edit -- it is every user enrolling again.
RSpec.describe "the passkey domain" do
  around do |example|
    original = SparrowAuth.config.webauthn_rp_id
    example.run
    SparrowAuth.config.webauthn_rp_id = original
  end

  def with_app_url(url)
    allow(SparrowAuth).to receive(:application_url).and_return(url)
  end

  describe "case" do
    # URI.parse preserves whatever was typed. A relying-party id is compared
    # against the origin's effective domain case-sensitively, so a capital
    # letter means no passkey can be enrolled or used at all -- and nothing
    # about the failure says why.
    it "is lower-cased however the address was typed" do
      with_app_url("https://EXAMPLE.COM")

      expect(SparrowAuth.application_host).to eq("example.com")
      expect(SparrowAuth.config.webauthn_rp_id).to eq("example.com")
    end

    it "is lower-cased when set explicitly too" do
      SparrowAuth.config.webauthn_rp_id = "Acme.TEST"

      expect(SparrowAuth.config.webauthn_rp_id).to eq("acme.test")
    end
  end

  describe "scope" do
    # The address box also means "where mail links point" and "where a processor
    # returns a customer". For those, somebody running at app.example.com may
    # reasonably type the apex. For this one it is not reasonable: a passkey
    # scoped to the apex is valid across every subdomain, so whoever takes over
    # blog.example.com can mount a ceremony the authenticator will satisfy.
    it "notices when the id is wider than the host being served" do
      SparrowAuth.config.webauthn_rp_id = "example.com"

      expect(SparrowAuth.config.webauthn_rp_id_widens?("app.example.com")).to be(true)
    end

    it "says nothing when the id matches the host" do
      SparrowAuth.config.webauthn_rp_id = "app.example.com"

      expect(SparrowAuth.config.webauthn_rp_id_widens?("app.example.com")).to be(false)
    end

    # Label boundaries, not string prefixes: "example.com" must not be read as
    # widening "notexample.com", which is somebody else's domain entirely.
    it "compares on label boundaries rather than by suffix" do
      SparrowAuth.config.webauthn_rp_id = "example.com"

      expect(SparrowAuth.config.webauthn_rp_id_widens?("notexample.com")).to be(false)
    end

    it "says nothing when there is no id to compare" do
      SparrowAuth.config.webauthn_rp_id = nil
      with_app_url("")

      expect(SparrowAuth.config.webauthn_rp_id_widens?("app.example.com")).to be(false)
    end
  end
end
