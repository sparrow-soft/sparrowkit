# frozen_string_literal: true

require "rails_helper"

# Real encrypted credentials on disk, not a stub. The behaviour worth proving
# lives in what these methods refuse to do -- hand a secret back, erase one
# because a form had to submit an empty box -- and a stub proves only that they
# were called.
RSpec.describe SparrowUi::Console::Settings do
  # A whole credentials tree, because that is now the shape: one top-level key
  # per gem, named after whoever reads it.
  def reset!(tree = nil)
    data = {"secret_key_base" => "dummy" * 16}
      .merge(described_class.deep_stringify(tree || {}))

    described_class.forget!
    Rails.application.credentials.write(data.to_yaml)
    described_class.forget!
  end

  def stored(module_key = :mail)
    described_class.forget!
    described_class.read(module_key)
  end

  before { reset! }
  after { reset! }

  describe ".move" do
    it "moves a subtree to a new key with its secrets intact" do
      # The reason this exists. A panel sees secrets masked, so it cannot
      # rename a section through write without losing the key inside it.
      reset!(mail: {transactional: {adapter: "postmark"}, second: {adapter: "mailgun", api_key: "mg-live-9876"}})

      expect(described_class.move(:mail, from: :second, to: :broadcast)).to be(true)

      expect(stored).not_to have_key(:second)
      expect(stored[:broadcast]).to eq(adapter: "mailgun", api_key: "mg-live-9876")
      expect(stored[:transactional]).to eq(adapter: "postmark")
    end

    it "does nothing when there is nothing under the old key" do
      reset!(mail: {transactional: {adapter: "postmark"}})

      expect(described_class.move(:mail, from: :second, to: :broadcast)).to be(false)
      expect(stored).to eq(transactional: {adapter: "postmark"})
    end

    it "only removes the old key when the new one is already there" do
      reset!(mail: {second: {adapter: "mailgun", api_key: "mg-old"}, broadcast: {adapter: "sendgrid", api_key: "sg-live"}})

      described_class.move(:mail, from: :second, to: :broadcast)

      expect(stored).to eq(broadcast: {adapter: "sendgrid", api_key: "sg-live"})
    end
  end

  describe ".for_display" do
    it "masks a secret to presence and its last four characters" do
      reset!(mail: {adapter: "postmark", api_key: "pm-live-9876"})

      expect(described_class.for_display(:mail)).to eq(
        adapter: "postmark",
        api_key: {secret: true, set: true, hint: "9876"}
      )
    end

    it "masks a secret INSIDE A SUBTREE" do
      # The flat version of this saw `transactional:` as one value under a name
      # that is not a secret, and passed the subtree to the view whole -- key
      # and all. Nesting silently turned the masking off, which is the one
      # thing this module exists to do.
      reset!(mail: {transactional: {adapter: "postmark", api_key: "pm-live-9876"}})

      expect(described_class.for_display(:mail)).to eq(
        transactional: {
          adapter: "postmark",
          api_key: {secret: true, set: true, hint: "9876"}
        }
      )
    end

    it "masks at any depth, however deep the panel nests" do
      reset!(mail: {one: {two: {three: {token: "abcd-5678"}}}})

      expect(described_class.for_display(:mail).dig(:one, :two, :three, :token))
        .to eq(secret: true, set: true, hint: "5678")
    end

    it "treats a subtree under a secret name as a secret rather than a section" do
      # The safe answer to "secret, or section?" is "secret". A key called
      # `credentials:` is one whatever shape it is in.
      reset!(mail: {credentials: {api_key: "pm-live-9876"}})

      expect(described_class.for_display(:mail)[:credentials]).to include(secret: true)
      expect(described_class.for_display(:mail)[:credentials]).not_to have_key(:api_key)
    end

    it "reports an absent secret as unset, with no hint" do
      reset!(mail: {transactional: {adapter: "postmark", api_key: ""}})

      expect(described_class.for_display(:mail).dig(:transactional, :api_key))
        .to eq(secret: true, set: false, hint: nil)
    end
  end

  describe ".write" do
    it "merges into a subtree rather than replacing it" do
      reset!(mail: {transactional: {adapter: "postmark", api_key: "pm-live-9876"}})

      described_class.write(:mail, {transactional: {adapter: "postmark", api_key: ""}})

      expect(stored[:transactional]).to eq(adapter: "postmark", api_key: "pm-live-9876")
    end

    it "drops a blank secret at any depth, so a save does not erase a stored key" do
      reset!(mail: {api_key: "top-9876", transactional: {api_key: "nested-9876"}})

      described_class.write(:mail, {api_key: "", transactional: {api_key: "  "}})

      expect(stored[:api_key]).to eq("top-9876")
      expect(stored[:transactional][:api_key]).to eq("nested-9876")
    end

    # The same rule, for the other way a field comes back saying nothing new.
    #
    # There were three examples here about an UNCHANGED marker: a secret field
    # used to render twelve bullets as its VALUE when one was stored, so the
    # marker had to be recognised and dropped on the way back or saving the
    # page would have overwritten a live key with decoration.
    #
    # The decoration moved to the placeholder, which browsers never submit. The
    # box posts blank when it is left alone, and the blank-secret rule above --
    # older than any of this -- already covers it. The marker, its branch in
    # `sanitize` and these examples all went together.

    it "writes a blank non-secret through, at any depth" do
      reset!(mail: {transactional: {adapter: "postmark", domain: "mail.acme.test"}})

      described_class.write(:mail, {transactional: {domain: ""}})

      expect(stored[:transactional][:domain]).to eq("")
    end

    it "removes a key given nil, so a panel can say a section has gone" do
      reset!(mail: {
        transactional: {adapter: "postmark"},
        broadcast: {adapter: "mailgun", api_key: "mg-live-9876"}
      })

      described_class.write(:mail, {broadcast: nil})

      expect(stored).not_to have_key(:broadcast)
      expect(stored[:transactional]).to eq(adapter: "postmark")
    end

    it "leaves a nil out of a section written for the first time" do
      # `nil` means "not this key" whether or not the section existed. Before,
      # a first save wrote the key with nothing after the colon, which read
      # back as nil and looked like a half-finished edit in the file.
      reset!(mail: {})

      described_class.write(:mail, {transactional: {adapter: "ses", region: "eu-west-1", access_key_id: nil}})

      expect(stored[:transactional]).to eq(adapter: "ses", region: "eu-west-1")
    end

    it "removes one setting without disturbing its neighbours" do
      reset!(mail: {transactional: {adapter: "mailgun", api_key: "mg-9876", domain: "mail.acme.test"}})

      described_class.write(:mail, {transactional: {adapter: "postmark", domain: nil}})

      expect(stored[:transactional]).to eq(adapter: "postmark", api_key: "mg-9876")
    end

    it "leaves the other modules' settings alone" do
      reset!(mail: {adapter: "postmark"}, auth: {provider: "google"})

      described_class.write(:mail, {adapter: "mailgun"})

      expect(stored(:auth)).to eq(provider: "google")
    end

    it "does not write into the tree Rails has memoised" do
      # read returns the decrypted credentials tree itself. Merging into it in
      # place would leave the process holding a configuration that is not the
      # one on disk.
      reset!(mail: {transactional: {adapter: "postmark", api_key: "pm-live-9876"}})
      before_write = described_class.read(:mail)

      described_class.write(:mail, {transactional: {adapter: "mailgun"}})

      expect(before_write[:transactional][:adapter]).to eq("postmark")
    end
  end

  # The names that decide what is printed on screen. A missed one is a
  # credential in a screenshot, so these are asserted by name rather than left
  # to a regex nobody reads.
  describe "what counts as a secret" do
    it "catches the obvious ones" do
      %w[api_key client_secret access_token password stripe_credential].each do |name|
        expect(described_class).to be_secret(name), "#{name} was not treated as a secret"
      end
    end

    # Both were rendering their real values onto the page. Paddle's matches none
    # of key, secret, token, password or credential; SMTP's is half of a login
    # pair and worth nothing to the person reading their own screen, which is
    # the whole argument for masking it.
    it "catches the two that were being printed" do
      expect(described_class).to be_secret("vendor_auth_code")
      expect(described_class).to be_secret("user_name")
    end

    it "leaves things that are not secrets alone" do
      %w[adapter default_from sender_name app_url region host port].each do |name|
        expect(described_class).not_to be_secret(name), "#{name} was masked and should not be"
      end
    end

    # The passkey settings, named individually because they are the ones a
    # loosely-worded rule catches.
    #
    # A bare `auth` in this regex -- added to catch Paddle's `vendor_auth_code`
    # -- matches every one of these, and a masked webauthn_rp_id renders into
    # the settings form as the literal text `{:secret=>true, :set=>true}`. The
    # relying-party id is a public domain name sent to every browser in every
    # ceremony; there is nothing in it to protect and a settings page that
    # cannot show it is broken.
    it "does not mask the passkey settings, which are public and are not secrets" do
      %w[webauthn_rp_id webauthn_rp_name webauthn_origin].each do |name|
        expect(described_class).not_to be_secret(name), "#{name} was masked and should not be"
      end
    end
  end
end
