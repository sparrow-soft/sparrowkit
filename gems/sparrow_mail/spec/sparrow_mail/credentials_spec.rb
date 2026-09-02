# frozen_string_literal: true

# Reading `sparrow_mail:` out of Rails credentials.
#
# This is what makes the console panel more than a form. Without it the panel
# writes a file nobody reads: values save, the page shows them saved, and the
# application goes on sending through whatever the initializer said.
#
# Tested against apply_credentials! directly rather than by booting a host, so
# the mapping is pinned in the gem's own Rails-free suite.
RSpec.describe "SparrowMail.apply_credentials!" do
  around do |example|
    SparrowMail.reset!
    example.run
    SparrowMail.reset!
  end

  def apply(tree)
    SparrowMail.apply_credentials!(tree)
  end

  it "changes nothing when there is nothing stored" do
    apply({})

    expect(SparrowMail.configuration.adapter).to be_nil
  end

  it "reads the transactional stream as the default adapter" do
    apply({transactional: {adapter: :postmark, api_key: "pm-live"}})

    expect(SparrowMail.configuration.adapter).to eq(:postmark)
    expect(SparrowMail.configuration.adapter_settings_for(:transactional)).to include(api_key: "pm-live")
  end

  it "reads the default sender" do
    apply({default_from: "Acme <hello@acme.test>"})

    expect(SparrowMail.configuration.default_from).to eq("Acme <hello@acme.test>")
  end

  it "declares any other key as a stream, exactly as an initializer would" do
    apply({
      transactional: {adapter: :postmark, api_key: "pm-live"},
      broadcast: {adapter: :mailgun, api_key: "mg-live", domain: "news.acme.test"}
    })

    expect(SparrowMail.configuration.adapter_for_stream(:broadcast)).to eq(:mailgun)
    expect(SparrowMail.configuration.adapter_settings_for(:broadcast))
      .to include(api_key: "mg-live", domain: "news.acme.test")
  end

  it "does not lend the transactional provider's key to a stream on another provider" do
    # The trap this gem was reworked to prevent. A key issued by one provider is
    # meaningless to another, so credentials must not be inherited across them.
    apply({
      transactional: {adapter: :postmark, api_key: "pm-live"},
      broadcast: {adapter: :mailgun, api_key: "mg-live"}
    })

    expect(SparrowMail.configuration.adapter_settings_for(:broadcast)).not_to include(api_key: "pm-live")
  end

  it "carries shared_identity through rather than dropping it" do
    # Without this a deliberate overlap is refused at boot, which would read as
    # the console having saved something broken.
    apply({
      transactional: {adapter: :postmark, api_key: "pm-live"},
      broadcast: {adapter: :postmark, api_key: "pm-live", shared_identity: true}
    })

    expect(SparrowMail.configuration.shared_identity?(:broadcast)).to be(true)
  end

  it "does not treat shared_identity as a provider setting" do
    apply({broadcast: {adapter: :postmark, api_key: "pm-live", shared_identity: true}})

    expect(SparrowMail.configuration.adapter_settings_for(:broadcast)).not_to have_key(:shared_identity)
  end

  # What the panel wrote before 1.3.0. Read as broadcast so that mail keeps
  # sending and the README's header stops being refused as unknown; the
  # panel removes the old key on its next save.
  it "reads the panel's old name for the broadcast stream as broadcast" do
    apply({
      transactional: {adapter: :postmark, api_key: "pm-live"},
      marketing: {adapter: :mailgun, api_key: "mg-live", domain: "news.acme.test"}
    })

    expect(SparrowMail.configuration.stream?(:broadcast)).to be(true)
    expect(SparrowMail.configuration.stream?(:marketing)).to be(false)
    expect(SparrowMail.configuration.adapter_for_stream(:broadcast)).to eq(:mailgun)
  end

  it "lets a broadcast key win over a stale old one beside it" do
    apply({
      transactional: {adapter: :postmark, api_key: "pm-live"},
      marketing: {adapter: :mailgun, api_key: "mg-old"},
      broadcast: {adapter: :sendgrid, api_key: "sg-live"}
    })

    expect(SparrowMail.configuration.adapter_for_stream(:broadcast)).to eq(:sendgrid)
    expect(SparrowMail.configuration.stream?(:marketing)).to be(false)
  end

  it "does not mistake default_from for a stream" do
    apply({default_from: "hello@acme.test", transactional: {adapter: :postmark}})

    expect(SparrowMail.configuration.streams).not_to include(:default_from)
  end

  it "reads a hand-edited file with string keys" do
    # `credentials:edit` is the other way in, and it produces whatever the
    # person typed. An adapter looking up :api_key does not find "api_key".
    #
    # Built rather than written as one literal so standardrb's Style/HashSyntax
    # does not object to the mixture, which is the thing being tested.
    settings = {adapter: "postmark"}
    settings["api_key"] = "pm-live"

    apply({transactional: settings})

    expect(SparrowMail.configuration.adapter_settings_for(:transactional)).to include(api_key: "pm-live")
  end

  # What the console panel does after it saves.
  #
  # The bug this exists for: the panel wrote credentials and nothing re-read
  # them, so the process that saved kept the configuration it built at boot.
  # The page said "Mail settings saved to your Rails credentials", the hub badge
  # beside it went on saying the module was not set up, and mail kept leaving
  # through the provider that had just been replaced -- until a restart, with
  # nothing anywhere saying so.
  describe "reloading after a save" do
    it "picks up a provider chosen since boot" do
      apply({})
      expect(SparrowMail.configuration.adapter).to be_nil

      allow(SparrowMail).to receive(:credentials)
        .and_return({transactional: {adapter: :postmark, api_key: "pm-live"}})
      SparrowMail.reload_credentials!

      expect(SparrowMail.configuration.adapter).to eq(:postmark)
    end

    # Coming back to switch provider is the ordinary reason to open the panel
    # twice, and merging would leave Postmark's key sitting under SendLayer --
    # a setting no page shows and no adapter asked for.
    # Asserted on a setting only the OLD provider had. Both happen to use
    # `api_key`, so checking that alone would pass under a merge too and prove
    # nothing -- `message_stream` is the one that has to disappear.
    it "replaces the previous provider's settings rather than merging over them" do
      apply({transactional: {adapter: :postmark, api_key: "pm-live", message_stream: "outbound"}})

      allow(SparrowMail).to receive(:credentials)
        .and_return({transactional: {adapter: :sendlayer, api_key: "sl-live"}})
      SparrowMail.reload_credentials!

      settings = SparrowMail.configuration.adapter_settings_for(:transactional)
      expect(SparrowMail.configuration.adapter).to eq(:sendlayer)
      expect(settings[:api_key]).to eq("sl-live")
      expect(settings).not_to have_key(:message_stream)
    end

    # Boot still merges, and has to: apply_credentials! runs before the host's
    # own initializers, and replacing there would be a promise about ordering
    # this method has no business making.
    it "leaves the boot path merging, as it always has" do
      SparrowMail.configure { |config| config.settings = {timeout: 30} }

      apply({transactional: {adapter: :postmark, api_key: "pm-live"}})

      expect(SparrowMail.configuration.adapter_settings_for(:transactional))
        .to include(timeout: 30, api_key: "pm-live")
    end
  end
end
