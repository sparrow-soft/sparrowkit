# frozen_string_literal: true

# Both, and in this order. fake_client alone leaves WebAuthn.configuration
# undefined — FakeClient reads it for a default argument — and until now that was
# masked by Rodauth requiring the gem's entry file while handling the first
# request. Any helper that builds an authenticator before making a request hit
# the unmasked version, which is a confusing failure a long way from its cause.
require "webauthn"
require "webauthn/fake_client"

# Drives the real WebAuthn ceremony against a software authenticator.
#
# WebAuthn::FakeClient is a genuine authenticator implementation: it generates a
# real key pair, signs real client data, and produces attestation and assertion
# objects that the webauthn gem verifies with the same code path a Touch ID
# credential goes through. What it does not exercise is the browser — conditional
# UI, the platform's own prompts, and the quirks that differ between them. Those
# are what the manual smoke test is for, and why there is one.
module PasskeyHelpers
  # The host Rails uses for request specs. The RP ID is derived from it, and a
  # credential is bound to the RP ID it was created under, so every step of a
  # ceremony has to agree on this exact string.
  ORIGIN = "http://www.example.com"

  def authenticator
    @authenticator ||= WebAuthn::FakeClient.new(ORIGIN)
  end

  # A separate authenticator, for specs with more than one person in them. One
  # FakeClient is one device; sharing it between two accounts would let a test
  # pass that should not — an assertion from the wrong person's key.
  def another_authenticator
    WebAuthn::FakeClient.new(ORIGIN)
  end

  # Find the input first, then read its value, because attribute order is not
  # something a page owes anybody. Rodauth's own templates write
  # `type=... name=... value=...`; Rails' form helpers write
  # `value=... autocomplete=... type=... name=...`. A regex pinning the two
  # attributes adjacent matched the first and silently returned nil for the
  # second, which surfaced as "no setup challenge in the form" on a page that
  # plainly had one.
  def field_value(html, name)
    tag = html[/<input\b[^>]*\bname="#{Regexp.escape(name)}"[^>]*>/]
    tag && tag[/\bvalue="([^"]*)"/, 1]
  end

  # Enrols a passkey the way the browser does: fetch the setup form, take the
  # challenge it carries, have the authenticator sign it, post the result back.
  #
  # The password goes with it because Rodauth re-authenticates before enrolling
  # a credential, and it is right to: adding a passkey is adding a permanent way
  # in, and somebody who walks up to an unlocked laptop should not be able to do
  # it in silence.
  def enroll_passkey(password: "correct horse battery staple", client: authenticator)
    get "/auth/webauthn-setup"

    challenge = field_value(response.body, "webauthn_setup_challenge")
    hmac = field_value(response.body, "webauthn_setup_challenge_hmac")
    raise "no setup challenge in the form" if challenge.nil?

    credential = client.create(challenge: challenge)

    post "/auth/webauthn-setup", params: {
      webauthn_setup: credential.to_json,
      webauthn_setup_challenge: challenge,
      webauthn_setup_challenge_hmac: hmac,
      password: password
    }
  end

  # Signs in with a passkey and no address typed at all — the discoverable
  # credential flow. The challenge comes from the autofill form that
  # webauthn_autofill renders into the login page footer.
  def sign_in_with_passkey(user_verified: true)
    get "/auth/login"

    challenge = field_value(response.body, "webauthn_auth_challenge")
    hmac = field_value(response.body, "webauthn_auth_challenge_hmac")
    raise "no auth challenge on the login page" if challenge.nil?

    assertion = authenticator.get(challenge: challenge, user_verified: user_verified)

    post "/auth/webauthn-login", params: {
      webauthn_auth: assertion.to_json,
      webauthn_auth_challenge: challenge,
      webauthn_auth_challenge_hmac: hmac
    }
  end
end

RSpec.configure do |config|
  config.include PasskeyHelpers, type: :request
end
