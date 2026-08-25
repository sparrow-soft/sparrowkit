# frozen_string_literal: true

# What the console panel says about how mail is configured.
#
# The rule this whole page exists under gets tested first and hardest: no
# credential value is ever in the output. Not truncated, not masked, not the
# first four characters. A key rendered on a page is a key in a screenshot, a
# screen recording and a browser history, and a key that has been photographed
# has to be rotated.
#
# Tested against the whole report rather than against the one method that
# formats settings, because the danger is not that the formatter is wrong. It is
# that a value reaches the page through some other route — an error message
# quoting the settings hash, a stream name, a detail string built by
# interpolation — and only a check over everything catches that.
# Looks like a real key on purpose. A test double that reads as obviously fake
# would still pass a check that only looks for the exact string, and the point
# is to catch a value reaching the page by any route.
#
# The prefix is deliberately NOT a real provider's. It used to be `sk_live_`,
# which is Stripe's, and GitHub's push protection blocked the first release for
# it -- correctly, since it cannot know a key is fake. Long and distinctive is
# what this needs; impersonating a format a scanner recognises only means every
# contributor's push gets refused. Keep the first eight characters distinctive:
# two assertions below check that neither end of the value reaches the page.
FAKE_PROVIDER_KEY = "zz_live_51NotARealKeyButLooksLikeOne"

RSpec.describe SparrowMail::Console::Report do
  # A configuration built from an empty environment, so the developer's own
  # SPARROW_MAIL_* variables cannot change what these specs see.
  def config(&block)
    SparrowMail::Configuration.new({}).tap { |c| block&.call(c) }
  end

  def report_for(config)
    described_class.new(config)
  end

  # Every string anywhere in the report, however deeply nested.
  def all_text(value)
    case value
    when Hash then value.flat_map { |k, v| [k.to_s] + all_text(v) }
    when Array then value.flat_map { |v| all_text(v) }
    else [value.to_s]
    end
  end

  def everything_rendered(report)
    all_text([report.summary, report.findings, report.streams]).join("\n")
  end

  describe "never printing a credential" do
    it "keeps the value out of every part of the report" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: FAKE_PROVIDER_KEY}
      }

      expect(everything_rendered(report_for(configuration))).not_to include(FAKE_PROVIDER_KEY)
    end

    # Masking is the usual compromise and it is not one. Half a key still
    # identifies which key it is, and enough of a screenshot narrows a search.
    it "does not print any part of it either" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: FAKE_PROVIDER_KEY}
      }

      rendered = everything_rendered(report_for(configuration))

      expect(rendered).not_to include(FAKE_PROVIDER_KEY[0, 8])
      expect(rendered).not_to include(FAKE_PROVIDER_KEY[-8..])
    end

    it "keeps a stream's own credential out too" do
      stream_secret = "mg_key_abcdefghijklmnop"
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: FAKE_PROVIDER_KEY}
        c.stream :broadcast, adapter: :mailgun, settings: {api_key: stream_secret}
      }

      rendered = everything_rendered(report_for(configuration))

      expect(rendered).not_to include(stream_secret)
      expect(rendered).not_to include(FAKE_PROVIDER_KEY)
    end

    # The useful half: a developer wants to know whether their key was picked
    # up, and the name answers that.
    it "does say which credentials are set, by name" do
      configuration = config { |c|
        c.adapter = :postmark
        c.settings = {api_key: FAKE_PROVIDER_KEY}
      }

      transactional = report_for(configuration).streams.first

      expect(transactional[:secrets]).to eq(["api_key"])
    end

    # Matched loosely so a provider adding a new secret next year is caught by
    # the rule that already exists.
    it "treats anything that sounds like a secret as one" do
      configuration = config { |c|
        c.adapter = :postmark
        c.settings = {
          api_secret: "s", auth_token: "t", password: "p", credentials: "c",
          domain: "example.com", region: "us-east-1"
        }
      }

      transactional = report_for(configuration).streams.first

      expect(transactional[:secrets]).to eq(%w[api_secret auth_token credentials password])
      expect(transactional[:plain]).to include("domain", "region")
    end
  end

  describe "what it flags" do
    it "says when nothing can send at all" do
      titles = report_for(config).findings.map { |f| f[:title] }

      expect(titles).to include("No provider is configured")
    end

    it "says when there is no default sender" do
      configuration = config { |c| c.adapter = :test }

      titles = report_for(configuration).findings.map { |f| f[:title] }

      expect(titles).to include("There is no default sender")
    end

    it "says when sandbox is on" do
      configuration = config { |c|
        c.adapter = :test
        c.default_from = "hello@example.com"
        c.sandbox = true
      }

      titles = report_for(configuration).findings.map { |f| f[:title] }

      expect(titles).to include("Sandbox is on")
    end

    # The trap this gem was reworked to prevent, reported before it bites. A
    # stream sending through a different provider inherits no credentials, so
    # one that forgot to declare its own fails to authenticate the first time it
    # sends — which for a marketing stream might be a month later.
    it "catches a stream that sends through another provider with no key of its own" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: "pm_key"}
        c.stream :broadcast, adapter: :mailgun, settings: {domain: "news.example.com"}
      }

      finding = report_for(configuration).findings.find { |f|
        f[:title].include?("broadcast")
      }

      # not_to be_nil rather than be_present: this suite has no ActiveSupport in
      # it, deliberately, and the gem depends on `mail` alone.
      expect(finding).not_to be_nil
      expect(finding[:level]).to eq(:error)
      expect(finding[:detail]).to include("not inherited across providers")
    end

    it "says nothing about a stream that did declare its own" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: "pm_key"}
        c.stream :broadcast, adapter: :mailgun, settings: {api_key: "mg_key"}
      }

      titles = report_for(configuration).findings.map { |f| f[:title] }

      expect(titles.grep(/broadcast/)).to be_empty
    end

    # A stream on the same provider inherits its credentials legitimately, so
    # this must not be reported as a fault.
    it "says nothing about a stream that only overrides a setting" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: "pm_key"}
        c.stream :broadcast, settings: {message_stream: "broadcast"}
      }

      titles = report_for(configuration).findings.map { |f| f[:title] }

      expect(titles.grep(/broadcast/)).to be_empty
    end

    # A stream on the same provider is never missing credentials of its own,
    # because it does not need any — it inherits them legitimately. Without the
    # same-provider guard this reports a stream as broken and says "it sends
    # through postmark while the default provider is postmark", which is
    # nonsense a developer would waste an afternoon on.
    it "does not accuse a same-provider stream when the default has no key either" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.stream :broadcast, settings: {message_stream: "broadcast"}
      }

      titles = report_for(configuration).findings.map { |f| f[:title] }

      expect(titles.grep(/broadcast/)).to be_empty
    end

    it "notes a stream that shares the transactional identity" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: "pm_key"}
        c.stream :broadcast, shared_identity: true
      }

      finding = report_for(configuration).findings.find { |f| f[:title].include?("identity") }

      expect(finding[:detail]).to include("sign-in codes")
    end

    it "flags nothing when everything is in order" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.com"
        c.settings = {api_key: "pm_key"}
      }

      expect(report_for(configuration).findings).to be_empty
    end
  end

  describe "the streams it lists" do
    it "always includes the transactional stream" do
      names = report_for(config).streams.map { |s| s[:name] }

      expect(names).to include(SparrowMail::Envelope::DEFAULT_STREAM)
    end

    it "says which provider each stream leaves by, and whether it was inherited" do
      configuration = config { |c|
        c.adapter = :postmark
        c.stream :broadcast, adapter: :mailgun, settings: {api_key: "mg"}
      }

      broadcast = report_for(configuration).streams.find { |s| s[:name] == :broadcast }

      expect(broadcast[:adapter]).to eq(:mailgun)
      expect(broadcast[:inherits_adapter]).to be(false)
    end
  end

  # Every other example here passes a configuration in, which is what let the
  # default argument name a method that does not exist for as long as it did:
  # `SparrowMail.config` instead of `SparrowMail.configuration`. Nothing failed
  # until the console hub called `Report.new` with no arguments, and then the
  # Mail card reported NoMethodError instead of a status.
  it "reads the live configuration when it is not given one" do
    expect { described_class.new.findings }.not_to raise_error
  end

  describe "the one-line status the console hub shows" do
    it "says unconfigured when there is no provider, because no mail can leave" do
      expect(report_for(config).status).to include(state: :unconfigured)
    end

    it "says ready, naming the provider the way the provider spells it" do
      configuration = config { |c|
        c.adapter = :sendgrid
        c.settings = {api_key: "SG.test"}
        c.default_from = "hello@example.test"
      }

      expect(report_for(configuration).status)
        .to eq({state: :ready, detail: "Sending through SendGrid."})
    end

    it "asks for attention when a setting is missing that will refuse mail later" do
      configuration = config { |c|
        c.adapter = :postmark
        c.settings = {api_key: "pm-test"}
      }

      expect(report_for(configuration).status)
        .to eq({state: :attention, detail: "There is no default sender."})
    end

    # The case that used to show green. A provider chosen and saved with an
    # empty key inherited the top-level settings, which were empty, and the
    # transactional stream was exempt from the credentials check -- so the panel
    # said "Sending through Postmark" and the first send was refused.
    it "refuses to call a provider ready when it is missing what it says it needs" do
      configuration = config { |c|
        c.adapter = :postmark
        c.default_from = "hello@example.test"
      }

      expect(report_for(configuration).status)
        .to eq({state: :attention, detail: "postmark is missing api_key."})
    end

    it "prefers an error over a warning when both are outstanding" do
      configuration = config { |c|
        c.adapter = :postmark
        c.settings = {api_key: "pm-test"}
        c.default_from = "hello@example.test"
        c.stream :broadcast, adapter: :mailgun
      }

      expect(report_for(configuration).status[:detail]).to match(/no credentials of its own/)
    end

    it "stays ready under sandbox, which is a note and the right state in development" do
      # A hub that says "check this" about the state it expects you to be in
      # teaches you to ignore it, which costs the badge its only job on the day
      # it means something.
      configuration = config { |c|
        c.adapter = :postmark
        c.settings = {api_key: "pm-test"}
        c.default_from = "hello@example.test"
        c.sandbox = true
      }

      expect(report_for(configuration).status).to include(state: :ready)
    end

    it "never puts a credential in the status, the same rule as the rest of the page" do
      configuration = config { |c|
        c.adapter = :postmark
        c.settings = {api_key: FAKE_PROVIDER_KEY}
      }

      expect(report_for(configuration).status.to_s).not_to include(FAKE_PROVIDER_KEY)
    end
  end

  # This gem cannot ask sparrow_ui for the rule -- sparrow_ui is a
  # development-group gem and this file is loaded in production -- so the rule
  # is copied, and copies drift. This one had `auth` and sparrow_ui's did not,
  # which meant two answers to "is this safe to print" and only one of them
  # deciding what the panel printed.
  #
  # Held in step here rather than by a comment asking somebody to remember.
  describe "the secret-name rule" do
    it "catches the names that were being printed" do
      %w[vendor_auth_code user_name api_key client_secret].each do |name|
        expect(name).to match(described_class::SECRET_NAME), "#{name} was not treated as a secret"
      end
    end
  end
end
