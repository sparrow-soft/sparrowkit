# frozen_string_literal: true

require "rails_helper"

# The bot protection card: the two Cloudflare Turnstile keys.
#
# A file of its own because the pair is handled unlike anything else on the
# page. Both names match the secret mask, and only one of them is a secret: the
# site key has to read back and be clearable, and the secret key must never
# reach the page at all.
RSpec.describe "the auth panel's Turnstile keys", type: :request do
  let(:panel) { "/sparrowkit/auth" }
  let(:secret) { "0x4AAAAAAAturnstile-secret-do-not-print-7Qz9" }

  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
    get "/sparrowkit", params: {credential_target: "development"}
  end

  def stored
    ConsoleCredentials.stored
  end

  # The fields a save always carries, plus the two boxes on this card as the
  # page renders them: the site key filled in with whatever is stored, the
  # secret key always blank.
  def save(overrides = {})
    patch panel, params: {
      webauthn_rp_id_override: "0",
      webauthn_rp_name_override: "0",
      sender_name: "Example",
      sender_email: "no-reply@example.com",
      signup_with_code: "1",
      passwords_enabled: "0",
      emailed_sign_in: "code",
      otp_secret: "",
      turnstile_site_key: "",
      turnstile_secret_key: ""
    }.merge(overrides)
  end

  it "labels both boxes and points each at its description" do
    get panel

    %w[auth_turnstile_site_key auth_turnstile_secret_key].each do |control|
      expect(response.body).to include(%(<label for="#{control}"))
      expect(response.body).to include(%(id="#{control}"))
      expect(response.body).to include(%(id="#{control}_hint"))
    end
  end

  it "saves both keys under sparrow_auth" do
    save(turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: secret)

    expect(response).to have_http_status(:redirect)
    expect(stored[:turnstile_site_key]).to eq("0x4AAAAAAAsite")
    expect(stored[:turnstile_secret_key]).to eq(secret)
  end

  it "never renders the secret key back, not even its last four characters" do
    save(turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: secret)
    follow_redirect!

    expect(response.body).not_to include(secret)
    expect(response.body).not_to include(secret[-4..])
    expect(response.body).to match(/id="auth_turnstile_secret_key"[^>]*value=""/)
    expect(response.body).to include("Already set. Leave blank to keep it.")
  end

  # The mask would hide it, because the name contains "key". The controller
  # reads this one public value past the mask on purpose; without that the box
  # would come back empty after every save and the next save would clear it.
  it "shows the stored site key back in its box" do
    ConsoleCredentials.reset!(sparrow_auth: {turnstile_site_key: "0x4AAAAAAAsite"})

    get panel

    expect(response.body).to match(/id="auth_turnstile_site_key"[^>]*value="0x4AAAAAAAsite"/)
  end

  it "keeps the stored secret key when its box comes back blank" do
    ConsoleCredentials.reset!(sparrow_auth: {
      turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: secret
    })

    save(turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: "")

    expect(stored[:turnstile_site_key]).to eq("0x4AAAAAAAsite")
    expect(stored[:turnstile_secret_key]).to eq(secret)
  end

  it "replaces the stored secret key when a new one is typed" do
    ConsoleCredentials.reset!(sparrow_auth: {
      turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: secret
    })

    save(turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: "0x4AAAAAAAnew")

    expect(stored[:turnstile_secret_key]).to eq("0x4AAAAAAAnew")
  end

  # The explicit way off. A blank site key alone would be dropped by the
  # secret mask's write rule, so the panel sends it as a deletion, and takes
  # the secret with it rather than leaving half a pair behind.
  it "turns Turnstile off and removes both keys when the site key is emptied" do
    ConsoleCredentials.reset!(sparrow_auth: {
      turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: secret
    })

    save(turnstile_site_key: "", turnstile_secret_key: "")

    expect(stored).not_to have_key(:turnstile_site_key)
    expect(stored).not_to have_key(:turnstile_secret_key)
  end

  # A request that never carried the box is not a request to clear it.
  it "leaves both keys alone when the request does not carry the site key box" do
    ConsoleCredentials.reset!(sparrow_auth: {
      turnstile_site_key: "0x4AAAAAAAsite", turnstile_secret_key: secret
    })

    patch panel, params: {
      webauthn_rp_id_override: "0",
      webauthn_rp_name_override: "0",
      signup_with_code: "1",
      passwords_enabled: "0",
      emailed_sign_in: "code"
    }

    expect(stored[:turnstile_site_key]).to eq("0x4AAAAAAAsite")
    expect(stored[:turnstile_secret_key]).to eq(secret)
  end

  it "keeps a typed site key on the page when a save is refused" do
    save(turnstile_site_key: "0x4AAAAAAAtyped", sender_email: "not-an-address")

    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to match(/id="auth_turnstile_site_key"[^>]*value="0x4AAAAAAAtyped"/)
    expect(stored).not_to have_key(:turnstile_site_key)
  end

  it "refuses a key that arrives as something other than a line of text" do
    save(turnstile_secret_key: {nested: "x"})

    expect(response).to have_http_status(:unprocessable_content)
    expect(stored).not_to have_key(:turnstile_secret_key)
  end
end
