# frozen_string_literal: true

require "rails_helper"

# The control panel, end to end: sparrow_ui's mount, this gem's console engine,
# the real Settings, and real Rails encrypted credentials on disk.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
AUTH_PANEL = "/sparrowkit/auth"

RSpec.describe "the auth control panel", type: :request do
  # sparrow_ui's gate refuses anything that is not local development, and it
  # runs as engine middleware ahead of this engine's routes. The suite runs in
  # the test environment, so development is the half that has to be stubbed;
  # the loopback half is satisfied by the integration session's REMOTE_ADDR.
  before do
    allow(Rails.env).to receive(:development?).and_return(true)
    ConsoleCredentials.reset!
  end

  def stored
    ConsoleCredentials.stored
  end

  # The three fields a save always carries, so a spec about one of them does not
  # have to restate the other two.
  def save(overrides = {})
    patch AUTH_PANEL, params: {
      webauthn_rp_id_override: "1",
      webauthn_rp_id: "example.com",
      webauthn_rp_name_override: "1",
      webauthn_rp_name: "Example",
      sender_name: "Example",
      sender_email: "no-reply@example.com",
      signup_with_code: "1",
      passwords_enabled: "0",
      emailed_sign_in: "code",
      otp_secret: ""
    }.merge(overrides)
  end

  describe "the hub" do
    # The address on the front page is now what passkeys bind to, so the front
    # page is where the consequence of changing it belongs. The auth panel
    # already says it; saying it only there leaves it on the page somebody is
    # no longer editing.
    it "says that the address decides the domain passkeys are bound to" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://example.com"})

      get "/sparrowkit"

      expect(response.body).to match(/changing it asks everybody with a passkey to enrol\s+again/i)
    end

    # Somebody who set a different passkey domain on the auth panel has decoupled
    # the two on purpose. Warning them that an address change breaks passkeys
    # would be false, and a warning that is sometimes false is one people learn
    # to click past.
    it "does not claim passkeys are at risk when a different domain is set for them" do
      ConsoleCredentials.reset!(
        sparrowkit: {app_url: "https://example.com"},
        sparrow_auth: {webauthn_rp_id: "passkeys.example.com"}
      )

      get "/sparrowkit"

      expect(response.body).not_to match(/changing it asks everybody with a passkey to enrol\s+again/i)
    end

    it "takes the product's name, so no panel has to ask for it again" do
      patch "/sparrowkit", params: {app_url: "https://example.com", app_name: "Zephyr Works"}

      get "/sparrowkit/auth"

      expect(response.body).to include("Zephyr Works")
    end

    it "lists the panel and links to it" do
      get "/sparrowkit"

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Authentication")
      expect(response.body).to include(%(href="#{AUTH_PANEL}"))
    end
  end

  describe "GET" do
    it "renders" do
      get AUTH_PANEL

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Save authentication settings")
    end

    it "gives every control a label of its own" do
      get AUTH_PANEL

      %w[
        auth_webauthn_rp_id auth_webauthn_rp_name auth_sender_name auth_sender_email
        auth_signup_with_code auth_passwords_enabled
        auth_otp_secret
      ].each do |control|
        expect(response.body).to include(%(<label for="#{control}"))
        expect(response.body).to include(%(id="#{control}"))
      end
    end

    it "describes every control, and points each one at its description" do
      get AUTH_PANEL

      described = response.body.scan(/aria-describedby="([^"]+)"/).flatten.uniq
      expect(described).not_to be_empty

      described.each do |id|
        expect(response.body).to include(%(id="#{id}"))
      end
    end

    it "shows the ladder as the engine actually ships it" do
      # Passkeys and emailed codes on with no switch; passwords off; signing up
      # with a code on. A panel that opened showing something else would be
      # describing an application nobody is running.
      get AUTH_PANEL

      expect(response.body).to match(/id="auth_signup_with_code"[^>]*checked/)
      expect(response.body).not_to match(/id="auth_passwords_enabled"[^>]*checked/)
    end

    # The two settled facts, said as facts. The alternative is a page with a
    # control that does nothing, which is worse than a page that states a rule.
    it "says that passkeys and email verification cannot be turned off" do
      get AUTH_PANEL

      expect(response.body).to include("Passkeys are always on")
      expect(response.body).to include("Email verification is always on")
      expect(response.body).to include("no switch")
    end

    it "says what passwords cost before offering them" do
      get AUTH_PANEL

      expect(response.body).to include("weakest sign-in method")
      expect(response.body).to include("somebody else's breach")
    end

    it "offers nothing about roles or permissions" do
      # Application policy, per ADR 0008, and a console that offered to
      # configure it would be re-inventing the role model that ADR refuses.
      get AUTH_PANEL

      # Field names, not prose. This asserted the absence of a retired word,
      # which passed only because the page happened to say "capabilities" —
      # the plural. The rename exposed it: "permissions" contains
      # "permission", and a spec that turns on which word form the copy uses
      # is not testing what it claims to.
      expect(response.body).not_to match(/name="role/)
      expect(response.body).not_to match(/name="admin_resolver"/)
      expect(response.body).not_to match(/name="permission/)
    end

    it "shows what is already stored" do
      ConsoleCredentials.reset!(sparrow_auth: {
        webauthn_rp_id: "acme.test",
        webauthn_rp_name: "Acme",
        mail_from: "Acme <no-reply@acme.test>"
      })

      get AUTH_PANEL

      expect(response.body).to match(/id="auth_webauthn_rp_id"[^>]*value="acme\.test"/)
      expect(response.body).to match(/id="auth_webauthn_rp_name"[^>]*value="Acme"/)

      # One stored mailbox, two boxes on the page. Matched across the tag: the
      # attributes are on separate lines in the template.
      expect(response.body).to match(/id="auth_sender_name".*?value="Acme"/m)
      expect(response.body).to match(/id="auth_sender_email".*?value="no-reply@acme\.test"/m)
    end

    it "reads a stored switch back off the credentials" do
      ConsoleCredentials.reset!(sparrow_auth: {signup_with_code: false, passwords_enabled: true})

      get AUTH_PANEL

      expect(response.body).not_to match(/id="auth_signup_with_code"[^>]*checked/)
      expect(response.body).to match(/id="auth_passwords_enabled"[^>]*checked/)
    end
  end

  # Nothing is hidden by the server that scripting would have to undo, save the
  # one warning that has nothing to say until an ID actually changes -- and its
  # sentence is in the field's own hint as well.
  describe "without JavaScript" do
    it "renders every control visible and reachable" do
      get AUTH_PANEL

      expect(response.body).not_to match(/<input[^>]*id="auth_[a-z_]+"[^>]*\shidden/m)
      expect(response.body).not_to match(/<section[^>]*\shidden/m)
    end

    # The apex-vs-www advice is the one piece of guidance that has to survive
    # scripting being off, because getting it wrong is not undone by editing
    # the field: every enrolled passkey dies with the change. It lives in the
    # field's own hint, rendered by the server, not in the script's warning.
    #
    # Two phrases rather than one exact sentence. This spec used to pin a
    # single string and failed the day the hint was rewritten into plainer
    # English, which is a spec reporting on prose rather than on the promise.
    # Shown, not asked for. Somebody who has already typed their address on the
    # front page should not meet an empty box wanting it again.
    it "shows the domain it inherited, and says where it came from" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://example.com"})

      get AUTH_PANEL

      expect(response.body).to include("example.com")
      expect(response.body).to match(/home page|front page/i)
      expect(response.body).to include(%(href="/sparrowkit"))
    end

    it "says what changing the Relying Party ID costs, whether or not it is changing" do
      get AUTH_PANEL

      expect(response.body).to include("example.com")
      expect(response.body).to match(/without the www/i)
    end

    # The domain is answered once, on the front page. This panel inherits it,
    # and an inherited value must not be quietly copied into this gem's own
    # settings the first time somebody saves anything here — because from then
    # on it stops tracking, and changing the address on the front page silently
    # leaves passkeys bound to the old domain.
    it "does not write the domain when it is only inherited" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://example.com"})

      save(webauthn_rp_id_override: "0", webauthn_rp_id: "example.com")

      expect(response).to have_http_status(:found)
      expect(stored[:webauthn_rp_id]).to be_nil
    end

    it "resumes inheriting when the override is turned off" do
      ConsoleCredentials.reset!(
        sparrowkit: {app_url: "https://example.com"},
        sparrow_auth: {webauthn_rp_id: "acme.test"}
      )

      save(webauthn_rp_id_override: "0", webauthn_rp_id: "acme.test")

      expect(stored[:webauthn_rp_id]).to be_nil
    end

    it "does not write the product name when it is only inherited" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://example.com", app_name: "Acme"})

      save(webauthn_rp_name_override: "0", webauthn_rp_name: "Acme")

      expect(response).to have_http_status(:found)
      expect(stored[:webauthn_rp_name]).to be_nil
    end

    it "writes the product name when somebody deliberately overrides it" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://example.com", app_name: "Acme"})

      save(webauthn_rp_name_override: "1", webauthn_rp_name: "Acme Accounts")

      expect(stored[:webauthn_rp_name]).to eq("Acme Accounts")
    end

    it "writes the domain when somebody deliberately overrides it" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://www.example.com"})

      save(webauthn_rp_id_override: "1", webauthn_rp_id: "example.com")

      expect(stored[:webauthn_rp_id]).to eq("example.com")
    end

    it "refuses an override with nothing in it, rather than storing a blank" do
      ConsoleCredentials.reset!(sparrowkit: {app_url: "https://example.com"})

      save(webauthn_rp_id_override: "1", webauthn_rp_id: "")

      expect(response).to have_http_status(:unprocessable_content)
      expect(stored[:webauthn_rp_id]).to be_nil
    end

    it "saves from a plain form post" do
      save

      expect(response).to have_http_status(:found)
      expect(stored[:webauthn_rp_id]).to eq("example.com")
    end
  end

  describe "saving" do
    it "writes the values under sparrowkit: auth:" do
      save

      expect(response).to have_http_status(:found)
      expect(stored).to include(
        webauthn_rp_id: "example.com",
        webauthn_rp_name: "Example",
        mail_from: "Example <no-reply@example.com>",
        signup_with_code: true
      )
    end

    # Clearing an overridden value is done by turning its switch off, not by
    # emptying the box. An empty box was ambiguous — it looked the same whether
    # somebody meant "go back to the product name" or "I have not typed it yet"
    # — and it is now refused, so the two cannot be confused.
    it "clears an override by turning it off, not by emptying the box" do
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_name: "Acme Accounts"})

      save(webauthn_rp_name_override: "0", webauthn_rp_name: "Acme Accounts")

      expect(stored[:webauthn_rp_name]).to be_nil
    end

    it "refuses an override with nothing in it, rather than storing a blank name" do
      save(webauthn_rp_name_override: "1", webauthn_rp_name: "")

      expect(response).to have_http_status(:unprocessable_content)
      expect(stored[:webauthn_rp_name]).to be_nil
    end

    it "records passwords being turned on" do
      save(passwords_enabled: "1")

      expect(stored[:passwords_enabled]).to eq(true)
    end

    it "takes the key back out when passwords are turned off again" do
      # A merge can only ever add. Presence IS the value here, because
      # SparrowUi masks by name and a key called `passwords_enabled` never comes
      # back as itself -- so leaving it behind would leave passwords on.
      save(passwords_enabled: "1")
      save(passwords_enabled: "0")

      expect(stored).not_to have_key(:passwords_enabled)
    end

    it "reads back what it just wrote, in the same process" do
      # Rails memoises the credentials object and ActiveSupport memoises the
      # decrypted tree inside it, so without a deliberate reset the page would
      # keep rendering the values that were there before the save -- for the
      # life of the server.
      save(webauthn_rp_id: "acme.test")
      get AUTH_PANEL

      expect(response.body).to match(/id="auth_webauthn_rp_id"[^>]*value="acme\.test"/)
    end

    it "says out loud when the Relying Party ID has changed" do
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_id: "acme.test"})

      save(webauthn_rp_id: "example.com")

      expect(flash[:alert]).to include("acme.test")
      expect(flash[:alert]).to include("has to enrol again")
    end

    it "says nothing about a Relying Party ID that is being set for the first time" do
      save

      expect(flash[:alert]).to be_nil
    end

    it "shows the warning on the page when a refused save changed the ID" do
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_id: "acme.test"})

      save(webauthn_rp_id: "example.com", signup_with_code: "maybe")

      expect(response).to have_http_status(422)
      expect(response.body).to match(/id="auth_rp_id_change"(?![^>]*\shidden)/m)
    end

    it "keeps the warning hidden while the ID is unchanged" do
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_id: "acme.test"})

      get AUTH_PANEL

      expect(response.body).to match(/id="auth_rp_id_change"[^>]*\shidden/m)
    end
  end

  describe "the signing keys" do
    it "never renders a stored secret back" do
      ConsoleCredentials.reset!(sparrow_auth: {
        otp_secret: "otp-live-do-not-print-9876"
      })

      get AUTH_PANEL

      expect(response.body).not_to include("otp-live-do-not-print-9876")
      expect(response.body).not_to include("api-live-do-not-print-5432")
    end

    # The last four characters moved out of the label and into the box, where
    # the question they answer -- which key is this -- is actually asked. What
    # is beside the label now is a tick, covered further down.
    it "shows presence and the last four characters instead" do
      ConsoleCredentials.reset!(sparrow_auth: {otp_secret: "otp-live-do-not-print-9876"})

      get AUTH_PANEL

      expect(response.body).to include(%(placeholder="••••9876"))
      expect(response.body).to include("Leave this blank to keep it")
    end

    it "keeps the stored key when the box comes back blank" do
      # The form CANNOT render the stored key, so it must submit an empty box.
      # Treating that as "erase it" would invalidate every outstanding one-time
      # code and API token on every save.
      ConsoleCredentials.reset!(sparrow_auth: {
        otp_secret: "otp-live-9876"
      })

      save(otp_secret: "")

      expect(stored[:otp_secret]).to eq("otp-live-9876")
    end

    it "replaces a stored key when a new one is typed" do
      ConsoleCredentials.reset!(sparrow_auth: {otp_secret: "otp-live-9876"})

      save(otp_secret: "otp-live-0001")

      expect(stored[:otp_secret]).to eq("otp-live-0001")
    end

    # The box stays EMPTY whatever is stored, and says which key is in it
    # through its placeholder.
    #
    # Empty is what makes the rest safe: a placeholder is never submitted, so
    # saving a page you only came to read posts a blank secret, and a blank
    # secret has been dropped rather than written since long before any of
    # this. Decoration in the value would have been a save that succeeds,
    # reports success, and replaces a live signing key with bullet characters.
    #
    # The placeholder carries the last four characters and nothing more. A key
    # rendered on a page is a key in the HTML, the browser cache and any
    # screenshot, and a key that has been photographed has to be rotated.
    it "shows the last four characters as a placeholder, never as a value" do
      ConsoleCredentials.reset!(sparrow_auth: {
        otp_secret: "otp-live-9876"
      })

      get AUTH_PANEL

      expect(response.body).to match(/id="auth_otp_secret"[^>]*value=""/)
      expect(response.body).to match(/id="auth_otp_secret"[^>]*placeholder="••••9876"/)

      expect(response.body).not_to include("otp-live-9876")
      expect(response.body).not_to include("api-live-5432")
      # Not even most of it, which is the shortcut that looks harmless.
      expect(response.body).not_to include("live-9876")
    end

    it "offers no placeholder when nothing is stored" do
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_id: "example.test"})

      get AUTH_PANEL

      expect(response.body).to match(/id="auth_otp_secret"[^>]*value=""/)
      expect(response.body).not_to match(/id="auth_otp_secret"[^>]*placeholder=/)
    end

    # The tick beside the label, which replaced the masked hint that used to
    # sit there. It answers "is there a key in here" at a glance; the box
    # answers "which one".
    it "marks a stored key with the same tick the nav uses" do
      ConsoleCredentials.reset!(sparrow_auth: {otp_secret: "otp-live-9876"})

      get AUTH_PANEL

      label = response.body[%r{<label for="auth_otp_secret".*?</label>}m]
      expect(label).to include("text-emerald-600")
      expect(label).to include("<title>Set</title>")
    end

    it "marks nothing beside a key that is not stored" do
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_id: "example.test"})

      get AUTH_PANEL

      label = response.body[%r{<label for="auth_otp_secret".*?</label>}m]
      expect(label).not_to include("text-emerald-600")
    end
  end

  describe "a value it will not accept" do
    it "refuses a Relying Party ID that is a URL, and writes nothing" do
      # The mistake people actually make: pasting it out of the browser bar.
      # Quietly stripping the scheme would be the kind of help that later reads
      # as a bug.
      save(webauthn_rp_id: "https://example.com")

      expect(response).to have_http_status(422)
      expect(response.body).to include("is not a domain")
      expect(stored).to be_empty
    end

    it "refuses a Relying Party ID with a port on it" do
      save(webauthn_rp_id: "example.com:3000")

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end

    it "accepts localhost, which is a domain and a secure origin" do
      # Where passkeys are actually developed against. A rule that insisted on a
      # dot would refuse the one RP ID every developer has.
      save(webauthn_rp_id: "localhost")

      expect(response).to have_http_status(:found)
      expect(stored[:webauthn_rp_id]).to eq("localhost")
    end

    it "refuses a Relying Party ID with a path on it" do
      save(webauthn_rp_id: "example.com/auth")

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end

    # Storing nothing still means "work the domain out at runtime", and that is
    # still reachable — it is now said by turning the switch off rather than by
    # emptying the box while the switch is on, which was ambiguous: an empty box
    # looked identical whether somebody meant "derive it" or "I have not typed
    # it yet". With no address on the front page either, this lands back on the
    # request, which is what SparrowAuth.application_host leaves it to.
    it "stores nothing when the override is off, which means derive it" do
      save(webauthn_rp_id_override: "0", webauthn_rp_id: "")

      expect(response).to have_http_status(:found)
      expect(stored[:webauthn_rp_id]).to be_nil
    end

    it "refuses a sender address that is not one" do
      save(sender_email: "Example")

      expect(response).to have_http_status(422)
      expect(response.body).to include("is not an email address")
      expect(stored).to be_empty
    end

    it "refuses a sender name with no address, because that is not a sender" do
      # Blanking both is how you fall back to the Mail panel's default. A name
      # on its own is neither that nor a usable mailbox.
      save(sender_name: "Example", sender_email: "")

      expect(response).to have_http_status(422)
      expect(response.body).to include("not somewhere mail can come from")
      expect(stored).to be_empty
    end

    it "takes both blank as falling back to the Mail panel" do
      save(sender_name: "", sender_email: "")

      expect(response).to have_http_status(:found)
      expect(stored[:mail_from]).to eq("")
    end

    it "refuses a switch that is neither on nor off" do
      save(passwords_enabled: "yes-please")

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end

    it "refuses a field sent as something other than a string, rather than falling over" do
      save(webauthn_rp_id: {evil: "example.com"})

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end

    it "keeps what was typed when it refuses" do
      save(webauthn_rp_name: "Acme", webauthn_rp_id: "not a domain")

      expect(response).to have_http_status(422)
      expect(response.body).to match(/id="auth_webauthn_rp_name"[^>]*value="Acme"/)
    end
  end

  describe "when credentials cannot be written" do
    before { ConsoleCredentials.without_key! }

    it "renders the form disabled, with the reason" do
      get AUTH_PANEL

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This page cannot save anything yet")
      expect(response.body).to include("no master key")
      expect(response.body).to include("disabled")
    end

    it "refuses a save instead of letting it raise" do
      save

      expect(response).to have_http_status(422)
      expect(response.body).to include("Nothing was saved")
    end
  end

  describe "the gate above it" do
    it "is 404 outside development, panel and all" do
      allow(Rails.env).to receive(:development?).and_return(false)

      get AUTH_PANEL

      expect(response).to have_http_status(:not_found)
    end
  end

  describe "the hub's card for this module" do
    # Unstubbed, against real credentials on disk, because the report's own
    # spec stubs `Settings.read` with an expected argument -- so it went on
    # passing while the report asked for a key nothing writes any more, and the
    # card read "Not set up" seconds after a successful save.
    it "reads the same key the panel writes" do
      save(webauthn_rp_id: "acme.test", otp_secret: "otp-live")

      get "/sparrowkit"

      expect(response.body).to include("Ready")
      expect(response.body).to include("Passkeys bind to acme.test.")
    end

    it "says not set up before anything is saved" do
      get "/sparrowkit"

      expect(response.body).to include("Not set up")
    end
  end

  describe "the prompt the hub offers" do
    # It exists to be pasted into somebody else's chat window, which is the
    # single worst destination on this console for an HMAC key.
    it "never contains a stored signing key" do
      save(otp_secret: "otp-live-notarealkey")

      get "/sparrowkit"

      expect(response.body).not_to include("otp-live-notarealkey")
      expect(response.body).not_to include("api-live-notarealkey")
    end

    it "says what is configured, so an assistant is not guessing" do
      save(webauthn_rp_id: "acme.test", passwords_enabled: "0")

      get "/sparrowkit"

      # The domain and where it came from, rather than an exact label. A saved
      # value is an override, and the prompt says so — an assistant told only
      # "acme.test" cannot tell whether changing the application's address would
      # move it.
      expect(response.body).to match(/Passkey domain[^\n]*acme\.test/)
      expect(response.body).to include("overriding the application")
      expect(response.body).to include("Passwords: off")
    end
  end

  # The point of the whole panel: a save has to reach the running application.
  #
  # Before the engine read `sparrow_auth:`, every spec above passed while the
  # panel was a form writing a file nobody read.
  describe "what the application actually uses afterwards" do
    def boot!
      # Exactly what the engine initializer does, against the file on disk.
      SparrowAuth.reset!
      SparrowAuth.configure do |config|
        SparrowAuth.credentials.each do |name, value|
          writer = :"#{name}="
          config.public_send(writer, value) if config.respond_to?(writer)
        end
      end
    end

    it "configures the engine from what the panel saved, with no other wiring" do
      save(webauthn_rp_id: "acme.test", webauthn_rp_name: "Acme")

      boot!

      expect(SparrowAuth.config.webauthn_rp_id).to eq("acme.test")
      expect(SparrowAuth.config.webauthn_rp_name).to eq("Acme")
    ensure
      SparrowAuth.reset!
    end

    it "joins the two sender boxes into the one mailbox the engine takes" do
      save(sender_name: "Acme", sender_email: "no-reply@acme.test")

      boot!

      expect(SparrowAuth.config.mail_from).to eq("Acme <no-reply@acme.test>")
    ensure
      SparrowAuth.reset!
    end

    it "puts it where a developer editing credentials by hand would look" do
      # `sparrow_auth:` at the top level, named after the gem that reads it.
      save

      ConsoleCredentials.forget!

      expect(Rails.application.credentials.config).to have_key(:sparrow_auth)
    end

    it "ignores a credentials key that is not a setting, rather than refusing to boot" do
      # Credentials are hand-editable. A typo there must not stop an
      # application starting, which is a far worse failure than a setting that
      # quietly does nothing.
      ConsoleCredentials.reset!(sparrow_auth: {webauthn_rp_id: "acme.test", nonsense_key: "x"})

      expect { boot! }.not_to raise_error
      expect(SparrowAuth.config.webauthn_rp_id).to eq("acme.test")
    ensure
      SparrowAuth.reset!
    end
  end
end
