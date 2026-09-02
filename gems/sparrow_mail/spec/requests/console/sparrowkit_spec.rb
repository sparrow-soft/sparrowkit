# frozen_string_literal: true

require "rails_helper"

# The control panel, end to end: sparrow_ui's mount, this gem's engine, the real
# Settings, and real Rails encrypted credentials on disk.
#
# Almost nothing here names a provider. What the page must offer comes from
# SparrowMail.registry and from each adapter's required_settings, so these
# specs go on holding when an adapter is added, and fail when the panel stops
# deriving its fields and starts listing them.
#
# The two adapters that ARE named -- postmark and mailgun -- are named because
# the behaviour under test is about two DIFFERENT providers with different
# required settings, and "two of them, whichever two" cannot be written without
# picking a pair.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
PANEL = "/sparrowkit/mail"

RSpec.describe "the mail control panel", type: :request do
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

  describe "GET" do
    it "renders" do
      get PANEL

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("Save mail settings")
    end

    it "offers every provider the registry knows about, in both cards" do
      get PANEL

      SparrowMail::Console::Adapters.all.each do |choice|
        expect(response.body).to include(%(value="#{choice.name}"))
      end

      expect(response.body).to include(%(name="primary[adapter]"))
      expect(response.body).to include(%(name="secondary[adapter]"))
    end

    it "asks for exactly the settings each adapter requires, in both cards" do
      get PANEL

      SparrowMail::Console::Adapters.all.map(&:name).each do |name|
        SparrowMail.registry.fetch(name).required_settings.each do |setting|
          expect(response.body).to include(%(name="primary[settings][#{name}][#{setting}]"))
          expect(response.body).to include(%(name="secondary[settings][#{name}][#{setting}]"))
        end
      end
    end

    it "labels a setting readably rather than title-casing its symbol" do
      get PANEL

      expect(response.body).to include("API key")
      expect(response.body).not_to include("Api key")
      expect(response.body).not_to include("api_key<")
    end

    it "gives every control a label of its own, including the dropdowns" do
      get PANEL

      expect(response.body).to include(%(<label for="mail_primary_adapter"))
      expect(response.body).to include(%(<label for="mail_secondary_adapter"))
      expect(response.body).to include(%(<label for="mail_sender_name"))
      expect(response.body).to include(%(<label for="mail_sender_email"))
    end

    it "selects the provider the credentials already name" do
      ConsoleCredentials.reset!(sparrow_mail: {transactional: {adapter: "postmark"}})

      get PANEL

      expect(response.body).to match(/<option value="postmark".*?selected/m)
    end

    it "says so when a stored provider is not registered at all" do
      ConsoleCredentials.reset!(sparrow_mail: {transactional: {adapter: "carrier_pigeon"}})

      get PANEL

      expect(response.body).to include("is not a registered adapter")
    end
  end

  # Nothing is hidden by the server that scripting would have to undo. The
  # script that reveals one provider's card is an enhancement; with it off the
  # page is complete and the form still saves the right thing.
  describe "without JavaScript" do
    it "renders both cards visible" do
      get PANEL

      expect(response.body).to include(%(id="mail_card_primary"))
      expect(response.body).to include(%(id="mail_card_secondary"))
      expect(response.body).not_to match(/id="mail_card_secondary"[^>]*\shidden/m)
    end

    it "renders every available provider's fields visible" do
      get PANEL

      expect(response.body).not_to match(/data-settings-for="[a-z]+"[^>]*\shidden/m)
    end

    it "saves a split configuration from a plain form post, with nothing revealed" do
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}}
      }

      expect(stored[:transactional]).to include(adapter: "postmark", api_key: "pm-0001")
      expect(stored[:marketing]).to include(adapter: "mailgun", api_key: "mg-0001")
    end
  end

  # Two boxes on the page, one RFC 5322 mailbox in the credentials, because
  # that is what SparrowMail::Configuration takes.
  describe "the sender name and address" do
    def save_sender(name, email)
      patch PANEL, params: {
        handles: "both",
        sender_name_override: "1",
        sender_name: name, sender_email: email,
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }
    end

    it "joins the two into one mailbox" do
      save_sender("Acme", "hello@acme.test")

      expect(stored[:default_from]).to eq("Acme <hello@acme.test>")
    end

    it "writes the address bare when there is no name" do
      save_sender("", "hello@acme.test")

      expect(stored[:default_from]).to eq("hello@acme.test")
    end

    it "drops a name with no address, because that is not a sender" do
      save_sender("Acme", "")

      expect(stored[:default_from]).to eq("")
    end

    it "quotes a name that would otherwise parse as two addresses" do
      # Unquoted, `Acme, Inc <a@b>` is a comma-separated list and the mail goes
      # to a recipient called "Acme".
      save_sender("Acme, Inc", "hello@acme.test")

      expect(stored[:default_from]).to eq(%("Acme, Inc" <hello@acme.test>))
    end

    it "splits a stored mailbox back into the two boxes" do
      ConsoleCredentials.reset!(sparrow_mail: {default_from: "Acme <hello@acme.test>"})

      get PANEL

      # Matched across the tag rather than as one string: the attributes are on
      # separate lines in the template.
      expect(response.body).to match(/id="mail_sender_name".*?value="Acme"/m)
      expect(response.body).to match(/id="mail_sender_email".*?value="hello@acme\.test"/m)
    end

    it "survives a round trip without collecting another pair of quotes" do
      # Saved, re-read into the form, saved again. The quotes come off on the
      # way out and back on on the way in; getting that wrong gives
      # `"""Acme, Inc""" <...>` after a few passes.
      save_sender("Acme, Inc", "hello@acme.test")
      get PANEL
      save_sender("Acme, Inc", "hello@acme.test")

      expect(stored[:default_from]).to eq(%("Acme, Inc" <hello@acme.test>))
    end

    # The product has one name and the front page took it. A second box here is
    # a second answer, and mail going out as "Acme Corp" while the passkey
    # prompt says "Acme" is two pages that each look right.
    it "shows the product's name rather than asking for it again" do
      ConsoleCredentials.reset!(
        sparrowkit: {app_name: "Zephyr Works"},
        sparrow_mail: {default_from: "hello@acme.test"}
      )

      get PANEL

      expect(response.body).to include("Zephyr Works")
    end

    it "stores a bare address when the name is only inherited" do
      ConsoleCredentials.reset!(sparrowkit: {app_name: "Zephyr Works"})

      patch PANEL, params: {
        handles: "both",
        sender_name_override: "0", sender_name: "Zephyr Works",
        sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }

      # Not "Zephyr Works <hello@acme.test>". A copy taken once stops following
      # the name it was copied from, and the From line then disagrees with
      # every other page the day somebody renames the product.
      expect(stored[:default_from]).to eq("hello@acme.test")
    end

    it "reads a bare stored address as an address, not a name" do
      ConsoleCredentials.reset!(sparrow_mail: {default_from: "hello@acme.test"})

      get PANEL

      expect(response.body).to match(/id="mail_sender_name".*?value=""/m)
      expect(response.body).to match(/id="mail_sender_email".*?value="hello@acme\.test"/m)
    end
  end

  describe "one provider for both kinds of mail" do
    it "writes one adapter and no marketing stream at all" do
      # Not a marketing stream that happens to match. NO marketing stream:
      # nothing for SparrowMail's verify_separation! to weigh up, and nothing
      # to keep in step.
      patch PANEL, params: {
        handles: "both",
        sender_name_override: "1",
        sender_name: "Acme", sender_email: "hello@acme.test",
        primary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "mail.acme.test"}}}
      }

      expect(response).to have_http_status(:found)
      expect(stored[:transactional]).to include(
        adapter: "mailgun", api_key: "mg-0001", domain: "mail.acme.test"
      )
      expect(stored[:default_from]).to eq("Acme <hello@acme.test>")
      expect(stored).not_to have_key(:marketing)
    end

    it "ignores the second card entirely" do
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}}
      }

      expect(stored).not_to have_key(:marketing)
    end

    it "takes a marketing stream back out when it is no longer wanted" do
      # A merge can only ever add. Leaving `marketing:` behind would leave a
      # second provider configured that nobody meant to keep sending through.
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "postmark", api_key: "pm-9876"},
        marketing: {adapter: "mailgun", api_key: "mg-9876", domain: "news.acme.test"}
      })

      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: ""}}}
      }

      expect(stored).not_to have_key(:marketing)
      expect(stored[:transactional][:api_key]).to eq("pm-9876")
    end
  end

  describe "a provider for each kind of mail" do
    it "gives the marketing stream its own adapter and its own settings" do
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}}
      }

      expect(response).to have_http_status(:found)
      expect(stored[:transactional]).to eq(adapter: "postmark", api_key: "pm-0001")
      expect(stored[:marketing]).to eq(
        adapter: "mailgun", api_key: "mg-0001", domain: "news.acme.test"
      )
    end

    it "reads the cards the other way round when the first handles marketing" do
      # The same configuration, typed from whichever provider the developer
      # already had. What is stored has no notion of a first card.
      patch PANEL, params: {
        handles: "marketing",
        sender_name: "", sender_email: "",
        primary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}},
        secondary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }

      expect(stored[:transactional]).to eq(adapter: "postmark", api_key: "pm-0001")
      expect(stored[:marketing]).to eq(
        adapter: "mailgun", api_key: "mg-0001", domain: "news.acme.test"
      )
    end

    it "never lets one card's credentials reach the other" do
      # The rule sparrow_mail enforces in Configuration#credentials_for, on the
      # panel that writes what it reads. Each provider supplies its own secrets
      # or has none.
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}}
      }

      expect(stored[:transactional]).not_to have_key(:domain)
      expect(stored[:transactional][:api_key]).to eq("pm-0001")
      expect(stored[:marketing][:api_key]).to eq("mg-0001")
    end

    it "writes nothing belonging to a provider that was not chosen" do
      # Every provider's fields are on the page at once, and with scripting off
      # they are all visible, so the request carries settings for providers
      # nobody picked. The chosen adapter's required_settings decide what is
      # persisted, not the parameter list.
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {
          adapter: "postmark",
          settings: {
            postmark: {api_key: "pm-0001"},
            mailgun: {api_key: "mg-nobody-picked-me", domain: "wrong.acme.test"}
          }
        },
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}}
      }

      expect(stored[:transactional]).to eq(adapter: "postmark", api_key: "pm-0001")
      expect(response.body).not_to include("mg-nobody-picked-me")
    end

    it "refuses a second card with no provider, and writes nothing" do
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }

      expect(response).to have_http_status(422)
      expect(response.body).to include("is not a registered adapter")
      expect(stored).to be_empty
    end

    it "refuses a kind of mail nobody can handle" do
      patch PANEL, params: {
        handles: "carrier_pigeons",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end

    it "comes back as a split configuration when the panel is reopened" do
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-9876", domain: "news.acme.test"}}}
      }
      get PANEL

      expect(response.body).to match(/id="mail_handles_transactional".*?\n?\s*checked/m)
      expect(response.body).to match(/id="mail_primary_adapter".*?<option value="postmark"[^>]*selected/m)
      expect(response.body).to match(/id="mail_secondary_adapter".*?<option value="mailgun"[^>]*selected/m)
      expect(response.body).to include("news.acme.test")
      expect(response.body).to include(%(placeholder="••••9876"))
    end
  end

  describe "secrets" do
    it "never renders a stored secret back, at any depth" do
      # for_display masks by NAME. A version of it that only looked at the top
      # level would hand `transactional:` to the view whole, key and all.
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "postmark", api_key: "pm-live-do-not-print-9876"},
        marketing: {adapter: "mailgun", api_key: "mg-live-do-not-print-5432", domain: "news.acme.test"}
      })

      get PANEL

      expect(response.body).not_to include("pm-live-do-not-print-9876")
      expect(response.body).not_to include("mg-live-do-not-print-5432")
    end

    it "shows presence and the last four characters instead" do
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "postmark", api_key: "pm-live-do-not-print-9876"}
      })

      get PANEL

      expect(response.body).to include(%(placeholder="••••9876"))
      expect(response.body).to include("Leave this blank to keep it")
    end

    it "keeps the stored secret when the field comes back blank" do
      # The form CANNOT render the stored key, so it must submit an empty box.
      # Treating that as "erase it" would wipe the key on every save, which is
      # the single most expensive way this page could be wrong.
      ConsoleCredentials.reset!(sparrow_mail: {
        sender_name: "", sender_email: "old@acme.test",
        transactional: {adapter: "postmark", api_key: "pm-live-9876"}
      })

      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "new@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: ""}}}
      }

      expect(stored[:transactional][:api_key]).to eq("pm-live-9876")
      expect(stored[:default_from]).to eq("new@acme.test")
    end

    it "keeps a blank secret in EITHER card" do
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "postmark", api_key: "pm-live-9876"},
        marketing: {adapter: "mailgun", api_key: "mg-live-5432", domain: "news.acme.test"}
      })

      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: ""}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "", domain: "news.acme.test"}}}
      }

      expect(stored[:transactional][:api_key]).to eq("pm-live-9876")
      expect(stored[:marketing][:api_key]).to eq("mg-live-5432")
    end

    it "replaces the stored secret when a new one is typed" do
      ConsoleCredentials.reset!(sparrow_mail: {transactional: {adapter: "postmark", api_key: "pm-live-9876"}})

      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-live-0001"}}}
      }

      expect(stored[:transactional][:api_key]).to eq("pm-live-0001")
    end

    it "leaves a provider's stored settings behind when that stream changes provider" do
      # A credential issued by one provider must not authenticate against
      # another. Carrying the Mailgun key forward into a Postmark configuration
      # would be a key confused quietly, which is worse than one missing
      # loudly: this way the adapter refuses to build and says which setting is
      # absent.
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "mailgun", api_key: "mg-live-9876", domain: "mail.acme.test"}
      })

      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: ""}}}
      }

      expect(stored[:transactional]).to eq(adapter: "postmark")
    end

    it "does not prefill one provider's settings beneath another" do
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "mailgun", api_key: "mg-live-9876", domain: "mail.acme.test"}
      })

      get PANEL

      # The stored domain belongs to mailgun and is shown in mailgun's box.
      expect(response.body).to match(/id="mail_primary_mailgun_domain".*?value="mail\.acme\.test"/m)
      # And in nobody else's -- ses also asks for settings, and none of them is
      # this one.
      expect(response.body).not_to match(/id="mail_secondary_mailgun_domain".*?value="mail.acme.test"/m)
    end
  end

  describe "one provider for both kinds, when that shares a reputation" do
    let(:same_provider) do
      {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0002"}}}
      }
    end

    it "saves, and says what SparrowMail will do about it" do
      patch PANEL, params: same_provider

      expect(response).to have_http_status(:found)
      expect(stored[:marketing]).to eq(adapter: "postmark", api_key: "pm-0002")
      expect(flash[:alert]).to include("keeps one reputation for both")
      expect(flash[:alert]).to include("API key")
    end

    it "shows the warning on the page, in SparrowMail's own words" do
      patch PANEL, params: same_provider
      get PANEL

      expect(response.body).to match(/id="mail_separation"(?![^>]*\shidden)/m)
      expect(response.body).to include("cannot tell them apart and keeps one reputation for both")
      expect(response.body).to include(
        "Bulk complaints would then decide whether transactional mail is delivered"
      )
      expect(response.body).to include("a different account, API key or")
    end

    it "keeps the warning hidden when the two providers differ" do
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-0001", domain: "news.acme.test"}}}
      }
      get PANEL

      expect(response.body).to match(/id="mail_separation"[^>]*\shidden/m)
    end

    it "says nothing about a provider with no reputation to lose" do
      # The test adapter records rather than sends. Two streams through it
      # cannot damage each other, so a warning would be noise.
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "", sender_email: "",
        primary: {adapter: "test"},
        secondary: {adapter: "test"}
      }

      expect(flash[:alert]).to be_nil
    end

    it "says nothing when one provider handles everything" do
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }

      expect(flash[:alert]).to be_nil
    end
  end

  describe "an adapter it will not accept" do
    it "refuses one that is not registered, and writes nothing" do
      patch PANEL, params: {handles: "both", sender_email: "hello@acme.test", primary: {adapter: "carrier_pigeon"}}

      expect(response).to have_http_status(422)
      expect(response.body).to include("is not a registered adapter")
      expect(stored).to be_empty
    end

    it "refuses a missing adapter parameter" do
      patch PANEL, params: {handles: "both", sender_email: "hello@acme.test"}

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end

    it "refuses a card sent as something other than a hash, rather than falling over" do
      patch PANEL, params: {handles: "both", sender_email: "", primary: "postmark"}

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end
  end

  describe "an adapter whose gem is not installed" do
    # Registry#fetch is lazy and raises ConfigurationError when the adapter's
    # dependency is absent -- the real case is Amazon SES without the AWS SDK.
    # Stubbed rather than uninstalled, because this suite's own bundle carries
    # the SDK so the adapter specs can run.
    let(:missing) do
      SparrowMail::ConfigurationError.new(
        "the ses adapter needs a gem that is not installed: " \
        "cannot load such file -- aws-sdk-sesv2. Add it to your Gemfile."
      )
    end

    before do
      allow(SparrowMail.registry).to receive(:fetch).and_call_original
      allow(SparrowMail.registry).to receive(:fetch).with(:ses).and_raise(missing)
    end

    it "says what to install, with the reason, rather than falling over" do
      get PANEL

      expect(response).to have_http_status(:ok)
      # Presented as work to do, not as a fault. The adapter is fine; this
      # application has simply not installed a dependency it deliberately does
      # not force on everyone.
      expect(response.body).to include("needs one more gem")
      expect(response.body).to include("aws-sdk-sesv2")
      expect(response.body).to include("restart this server")
    end

    # Against the provider it concerns, not at the foot of the page.
    #
    # It used to be a permanent list of every adapter needing a gem, which a
    # developer who had chosen Postmark and would never use Amazon SES read on
    # every visit. `data-settings-for` is the attribute the page's own script
    # already uses to reveal the chosen provider's settings, so this rides on
    # that and appears only when SES is the selection.
    it "shows it against SES rather than to everybody" do
      get PANEL

      expect(response.body).to match(/data-settings-for="ses"[^>]*>\s*<p[^>]*>\s*Amazon SES needs one more gem/m)
    end

    # Disabled, it was a dead end: greyed out, saying a gem was needed, with no
    # way to find out which one. Choosing it is how you ask.
    it "can be chosen, so that the reason can be read" do
      get PANEL

      expect(response.body.scan(/<option value="ses"[^>]*disabled/)).to be_empty
      expect(response.body.scan('<option value="ses"').size).to eq(2)
    end

    it "still renders every other adapter" do
      get PANEL

      expect(response.body).to include(%(name="primary[settings][postmark][api_key]"))
    end

    it "refuses to save it" do
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "ses", settings: {ses: {region: "us-east-1"}}}
      }

      expect(response).to have_http_status(422)
      expect(stored).to be_empty
    end
  end

  # Amazon SES is named here because the behaviour under test is a setting
  # with a known set of values and settings an adapter can find elsewhere,
  # and SES is the one shipped adapter that has both. The panel itself still
  # knows nothing about it: the region list and the hints come from the
  # adapter class, through SparrowMail::Console::Adapters.
  describe "a provider whose adapter says more about its settings" do
    let(:ses) { SparrowMail.registry.fetch(:ses) }

    def ses_field(body, card, setting)
      body[/<(select|input)[^>]*id="mail_#{card}_ses_#{setting}"[^>]*>/m]
    end

    it "renders a dropdown for a setting whose values the adapter listed" do
      get PANEL

      expect(ses_field(response.body, :primary, :region)).to start_with("<select")
      expect(ses_field(response.body, :secondary, :region)).to start_with("<select")
    end

    it "offers every region the adapter names, and only those" do
      get PANEL

      primary = response.body[/id="mail_primary_ses_region".*?<\/select>/m]
      offered = primary.scan(/<option value="([^"]*)"/).flatten.reject(&:empty?)

      expect(offered).to eq(ses.setting_choices(:region).map(&:first))
      expect(primary).to include("N. Virginia")
    end

    it "starts with nothing chosen rather than defaulting to a region" do
      # A default of us-east-1 would be right for a lot of people and silently
      # wrong for the rest, and SES refuses a send from the wrong region with
      # an error about an unverified identity -- nowhere near the actual cause.
      get PANEL

      expect(response.body).to match(/id="mail_primary_ses_region".*?<option value="" selected>/m)
    end

    it "asks for the credentials the adapter does not insist on" do
      get PANEL

      expect(response.body).to include(%(name="primary[settings][ses][access_key_id]"))
      expect(response.body).to include(%(name="primary[settings][ses][secret_access_key]"))
    end

    it "does not call them optional, because a send cannot do without them" do
      # The SDK may already have credentials from the environment, which is
      # why the adapter builds without them; that is not the same as a
      # developer being free to skip the box, which is what "Optional" says.
      # The hint beneath the box is where the blank-is-fine case is explained.
      get PANEL

      %i[region access_key_id secret_access_key].each do |setting|
        label = response.body[/<label for="mail_primary_ses_#{setting}".*?<\/label>/m]

        expect(label).not_to include("Optional")
      end
    end

    it "marks a setting optional when an adapter says it has no need of it" do
      pigeon = Class.new(SparrowMail::Adapters::Base) do
        adapter_name :racing_pigeon
        required_settings :loft
        optional_settings :ring_id
      end
      SparrowMail.register_adapter(:racing_pigeon, pigeon)

      get PANEL

      ring = response.body[/<label for="mail_primary_racing_pigeon_ring_id".*?<\/label>/m]
      loft = response.body[/<label for="mail_primary_racing_pigeon_loft".*?<\/label>/m]

      expect(ring).to include("Optional")
      expect(loft).not_to include("Optional")
    end

    it "masks both credentials, the way it masks any other key" do
      # sparrow_ui's secret field: a text box masked in CSS, never a
      # `type="password"`, which is what would make a browser offer to save an
      # AWS key into the developer's password manager.
      get PANEL

      %i[access_key_id secret_access_key].each do |setting|
        field = ses_field(response.body, :primary, setting)

        expect(field).to start_with("<input")
        expect(field).to include("-webkit-text-security:disc")
        expect(field).not_to include('type="password"')
      end
    end

    it "shows the adapter's own sentence about a setting" do
      get PANEL

      expect(response.body).to include("Needed unless the AWS SDK already has credentials")
    end

    it "saves the region and both credentials" do
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "ses", settings: {ses: {
          region: "eu-west-1", access_key_id: "AKIAEXAMPLE", secret_access_key: "s3cr3t"
        }}}
      }

      expect(response).to have_http_status(:found)
      expect(stored[:transactional]).to eq(
        adapter: "ses", region: "eu-west-1", access_key_id: "AKIAEXAMPLE", secret_access_key: "s3cr3t"
      )
    end

    it "saves the region alone, leaving credentials to the AWS SDK" do
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "ses", settings: {ses: {region: "eu-west-1", access_key_id: "", secret_access_key: ""}}}
      }

      expect(stored[:transactional]).to eq(adapter: "ses", region: "eu-west-1")
    end

    it "keeps stored credentials when the boxes are left blank on a later save" do
      ConsoleCredentials.reset!(sparrow_mail: {
        transactional: {adapter: "ses", region: "eu-west-1", access_key_id: "AKIAEXAMPLE", secret_access_key: "s3cr3t"}
      })

      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "",
        primary: {adapter: "ses", settings: {ses: {region: "eu-west-2", access_key_id: "", secret_access_key: ""}}}
      }

      expect(stored[:transactional]).to eq(
        adapter: "ses", region: "eu-west-2", access_key_id: "AKIAEXAMPLE", secret_access_key: "s3cr3t"
      )
    end

    it "selects the stored region" do
      ConsoleCredentials.reset!(sparrow_mail: {transactional: {adapter: "ses", region: "eu-west-1"}})

      get PANEL

      expect(response.body).to match(/id="mail_primary_ses_region".*?<option value="eu-west-1" selected>/m)
    end

    it "keeps a stored region the list does not know, so saving cannot change it" do
      # Typed by hand into the credentials file, or newer than the SDK's data.
      # Either way it was working, and a page that quietly replaced it with
      # "Choose one" would have a save button that breaks mail.
      ConsoleCredentials.reset!(sparrow_mail: {transactional: {adapter: "ses", region: "xx-moon-1"}})

      get PANEL

      expect(response.body).to match(/id="mail_primary_ses_region".*?<option value="xx-moon-1" selected>xx-moon-1</m)
    end
  end

  describe "when credentials cannot be written" do
    before { ConsoleCredentials.without_key! }

    it "renders the form disabled, with the reason" do
      get PANEL

      expect(response).to have_http_status(:ok)
      expect(response.body).to include("This page cannot save anything yet")
      expect(response.body).to include("no master key")
      expect(response.body).to include("disabled")
    end

    it "refuses a save instead of letting it raise" do
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-0001"}}}
      }

      expect(response).to have_http_status(422)
      expect(response.body).to include("Nothing was saved")
    end
  end

  describe "reading back what it just wrote" do
    it "does so in the same process" do
      # Rails memoises the credentials object and ActiveSupport memoises the
      # decrypted tree inside it, so without a deliberate reset the page would
      # keep rendering the values that were there before the save -- for the
      # life of the server.
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "hello@acme.test",
        primary: {adapter: "sendlayer", settings: {sendlayer: {api_key: "sl-9876"}}}
      }
      get PANEL

      expect(response.body).to include("hello@acme.test")
      expect(response.body).to include(%(placeholder="••••9876"))
    end
  end

  describe "the prompt the hub offers" do
    # It exists to be pasted into somebody else's chat window, which is the
    # single worst destination on this console for an API key.
    it "never contains a stored key" do
      patch PANEL, params: {
        handles: "both",
        sender_name_override: "1",
        sender_name: "Acme", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-live-notarealkey"}}}
      }

      get "/sparrowkit"

      expect(response.body).not_to include("pm-live-notarealkey")
    end

    it "names the configured provider, so an assistant is not guessing" do
      patch PANEL, params: {
        handles: "both",
        sender_name_override: "1",
        sender_name: "Acme", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-live-1234"}}}
      }

      get "/sparrowkit"

      expect(response.body).to include("Transactional provider: Postmark")
      expect(response.body).to include("delivery_method = :sparrow_mail")
    end
  end

  # The point of the whole panel, and the thing that was missing for as long as
  # this console existed: a save has to reach the running application.
  #
  # Before the railtie read `sparrow_mail:`, every spec above passed while the
  # panel was a form writing a file nobody read. Values saved, the page showed
  # them saved, and mail kept going out through whatever the initializer said.
  describe "what the application actually uses afterwards" do
    it "sends through the provider the panel saved, with no other wiring" do
      patch PANEL, params: {
        handles: "both",
        sender_name_override: "1",
        sender_name: "Acme", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-live-1234"}}}
      }

      # Exactly what a boot does, against the file the panel just wrote.
      SparrowMail.reset!
      SparrowMail.apply_credentials!

      expect(SparrowMail.configuration.adapter).to eq(:postmark)
      expect(SparrowMail.configuration.default_from).to eq("Acme <hello@acme.test>")
      expect(SparrowMail.configuration.adapter_settings_for(:transactional)).to include(api_key: "pm-live-1234")
    ensure
      SparrowMail.reset!
    end

    it "gives the marketing stream its own provider, the way the panel split them" do
      patch PANEL, params: {
        handles: "transactional",
        sender_name: "Acme", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-live-1234"}}},
        secondary: {adapter: "mailgun", settings: {mailgun: {api_key: "mg-live-5678", domain: "news.acme.test"}}}
      }

      SparrowMail.reset!
      SparrowMail.apply_credentials!

      expect(SparrowMail.configuration.adapter_for_stream(:marketing)).to eq(:mailgun)
      expect(SparrowMail.configuration.adapter_settings_for(:marketing)).to include(api_key: "mg-live-5678")
    ensure
      SparrowMail.reset!
    end

    it "puts it where a developer editing credentials by hand would look" do
      # `sparrow_mail:` at the top level, named after the gem that reads it --
      # not nested under an umbrella key somebody has to be told about.
      patch PANEL, params: {
        handles: "both",
        sender_name: "", sender_email: "hello@acme.test",
        primary: {adapter: "postmark", settings: {postmark: {api_key: "pm-live-1234"}}}
      }

      ConsoleCredentials.forget!
      tree = Rails.application.credentials.config

      expect(tree).to have_key(:sparrow_mail)
      expect(tree[:sparrow_mail]).to include(:default_from, :transactional)
    end
  end

  # Two copies of one rule, held in step.
  #
  # sparrow_ui's SECRET_NAME decides what the panel prints; sparrow_mail keeps
  # its own because it may not know sparrow_ui exists -- it is a
  # development-group gem and sparrow_mail is loaded in production. So the rule
  # is copied deliberately, and copies drift: this one had `auth` and
  # sparrow_ui's did not, so the two disagreed about which values were safe to
  # show and only one of them was deciding.
  #
  # Asserted HERE rather than beside the constant, because this is the suite
  # where both gems are actually loaded. The version next to the constant could
  # only skip itself, and a skipped test holds nothing in step.
  describe "the secret-name rule" do
    it "is the same in both gems" do
      expect(SparrowMail::Console::Report::SECRET_NAME.source)
        .to eq(SparrowUi::Console::Settings::SECRET_NAME.source)
    end
  end
end
