# frozen_string_literal: true

require "rails_helper"

# What the console hub's Authentication card says.
#
# Reads the same store the panel writes -- the credentials tree -- rather than
# SparrowAuth.config. A card fed from the live configuration would report a
# value set in the host's initializer, which the panel neither wrote nor can
# change, and "Ready" would then be about a different setting than the one the
# developer is looking at.

# A key long enough to be plausible, so a check that looks for it catches a
# value reaching the card by any route.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
FAKE_HMAC = "b6f3d1a9c2e84f07a5d3b1c9e7f2a8d4"

RSpec.describe SparrowAuth::Console::Report do
  def stub_credentials(tree)
    allow(::SparrowUi::Console::Settings).to receive(:read).with(SparrowAuth::CREDENTIALS_KEY).and_return(tree)
  end

  it "says unconfigured with no domain anywhere, because no passkey can be enrolled" do
    stub_credentials({})
    allow(SparrowAuth).to receive(:application_host).and_return(nil)

    expect(described_class.new.status)
      .to include(state: :unconfigured, detail: /enrolled/i)
  end

  it "says unconfigured when the credentials have no sparrow_auth key at all" do
    # Which is every application on the day it installs this. Settings.read
    # answers {} rather than nil for a key that is not there, so that is the
    # shape worth pinning -- and this spec asserts the guarantee rather than
    # assuming it, since the two classes are in different gems.
    allow(::SparrowUi::Console::Settings).to receive(:all).and_return({})

    # And no address on the front page either. Since the domain is inherited
    # from there, "unconfigured" now means neither place has one — an
    # application that has answered on the front page is ready without ever
    # touching this panel, which is the point of the change.
    allow(SparrowAuth).to receive(:application_host).and_return(nil)

    expect(::SparrowUi::Console::Settings.read(SparrowAuth::CREDENTIALS_KEY)).to eq({})
    expect(described_class.new.status).to include(state: :unconfigured)
  end

  it "says ready once the domain and both signing keys are set" do
    stub_credentials({
      webauthn_rp_id: "example.test",
      otp_secret: FAKE_HMAC,
      api_token_secret: FAKE_HMAC
    })

    expect(described_class.new.status)
      .to eq({state: :ready, detail: "Passkeys bind to example.test."})
  end

  # It used to say "Check this -- one-time codes cannot be verified" when the
  # signing keys were blank, which was false. Rails derives both from the master
  # key, and the panel now says in as many words that blank is right for almost
  # every application.
  #
  # So the card was nagging about the recommended configuration. A badge that
  # says "check this" about the state it just told you to be in is a badge you
  # learn to ignore, and then it is worth nothing on the day it means something.
  it "is ready with the signing keys blank, which is what the panel recommends" do
    stub_credentials({webauthn_rp_id: "example.test"})

    expect(described_class.new.status).to eq({state: :ready, detail: "Passkeys bind to example.test."})
  end

  it "is ready with them set too, since setting one is a legitimate choice" do
    stub_credentials({
      webauthn_rp_id: "example.test",
      otp_secret: FAKE_HMAC,
      api_token_secret: {secret: true, set: true}
    })

    expect(described_class.new.status).to include(state: :ready)
  end

  it "never puts a signing key in the status" do
    stub_credentials({
      webauthn_rp_id: "example.test",
      otp_secret: FAKE_HMAC,
      api_token_secret: FAKE_HMAC
    })

    expect(described_class.new.status.to_s).not_to include(FAKE_HMAC)
  end

  # The domain is inherited from the address on the front page unless this panel
  # overrides it. A report reading only this gem's own key calls a perfectly
  # configured application unconfigured, on the very page that just took the
  # address — and the badge it draws is the one somebody trusts to tell them
  # whether they are ready.
  describe "when the domain is inherited rather than stored here" do
    it "is ready, and says which domain passkeys will bind to" do
      allow(SparrowAuth).to receive(:application_host).and_return("example.com")
      allow(::SparrowUi::Console::Settings).to receive(:read).and_return({})

      status = SparrowAuth::Console::Report.new.status

      expect(status[:state]).to eq(:ready)
      expect(status[:detail]).to include("example.com")
    end

    it "is unconfigured only when there is no domain from either place" do
      allow(SparrowAuth).to receive(:application_host).and_return(nil)
      allow(::SparrowUi::Console::Settings).to receive(:read).and_return({})

      expect(SparrowAuth::Console::Report.new.status[:state]).to eq(:unconfigured)
    end
  end
end
