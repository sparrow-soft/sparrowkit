# frozen_string_literal: true

require "rails_helper"

# Where the passkey domain and the product name come from when nobody typed
# them into the auth settings.
#
# A passkey is permanently bound to this domain, so getting it wrong is not
# fixed by changing a setting — it is fixed by asking every person who has one
# to enrol again. It therefore must not be a thing somebody can forget to fill
# in on a second page after already answering it on the first.
RSpec.describe "the passkey domain, and where it comes from" do
  around do |example|
    original = SparrowAuth.config.webauthn_rp_id
    example.run
    SparrowAuth.config.webauthn_rp_id = original
  end

  def with_shared_address(url)
    allow(SparrowAuth).to receive(:application_url).and_return(url)
  end

  it "uses what the auth settings say, when they say anything" do
    SparrowAuth.config.webauthn_rp_id = "passkeys.example.com"
    with_shared_address("https://www.example.com")

    expect(SparrowAuth.config.webauthn_rp_id).to eq("passkeys.example.com")
  end

  # The whole point. One address, typed on the front page, and the auth
  # settings inherit it rather than asking for it again.
  it "falls back to the host of the application's own address" do
    SparrowAuth.config.webauthn_rp_id = nil
    with_shared_address("https://example.com")

    expect(SparrowAuth.config.webauthn_rp_id).to eq("example.com")
  end

  it "takes only the host, because a passkey binds to a bare domain" do
    SparrowAuth.config.webauthn_rp_id = nil
    with_shared_address("http://localhost:3000/somewhere")

    expect(SparrowAuth.config.webauthn_rp_id).to eq("localhost")
  end

  # Unchanged behaviour, and it has to stay: an application that has set
  # neither still works, by reading the domain off the request it is answering.
  it "stays nil when nothing is set anywhere, so the request decides" do
    SparrowAuth.config.webauthn_rp_id = nil
    with_shared_address("")

    expect(SparrowAuth.config.webauthn_rp_id).to be_nil
  end

  it "stays nil rather than guessing at an address it cannot parse" do
    SparrowAuth.config.webauthn_rp_id = nil
    with_shared_address("not a url")

    expect(SparrowAuth.config.webauthn_rp_id).to be_nil
  end

  describe "the name shown in the passkey prompt" do
    around do |example|
      original = SparrowAuth.config.webauthn_rp_name
      example.run
      SparrowAuth.config.webauthn_rp_name = original
    end

    def with_shared_name(name)
      allow(SparrowAuth).to receive(:application_name).and_return(name)
    end

    it "uses what the auth settings say, when they say anything" do
      SparrowAuth.config.webauthn_rp_name = "Acme Accounts"
      with_shared_name("Acme")

      expect(SparrowAuth.config.webauthn_rp_name).to eq("Acme Accounts")
    end

    # The same argument as the domain: it is one fact about the product, and a
    # second box asking for it again is a second answer waiting to disagree.
    it "falls back to the product name from the application's own settings" do
      SparrowAuth.config.webauthn_rp_name = nil
      with_shared_name("Acme")

      expect(SparrowAuth.config.webauthn_rp_name).to eq("Acme")
    end

    # Unchanged, and it has to stay: WebAuthn then shows the host, which reads
    # like a machine talking but is better than showing nothing.
    it "stays nil when nothing is set anywhere, so the request decides" do
      SparrowAuth.config.webauthn_rp_name = nil
      with_shared_name("")

      expect(SparrowAuth.config.webauthn_rp_name).to be_nil
    end
  end
end
