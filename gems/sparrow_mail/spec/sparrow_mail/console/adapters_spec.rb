# frozen_string_literal: true

require "spec_helper"

# Field#secret? asks sparrow_ui what counts as a secret rather than keeping a
# second copy of the rule. Loading the gem is enough -- Settings touches Rails
# only inside the methods that read and write credentials.
require "sparrow_ui"
require "sparrow_mail/console/adapters"

RSpec.describe SparrowMail::Console::Adapters do
  describe ".all" do
    # Everything the registry knows EXCEPT the ones that hand mail to nobody:
    # :test records in memory and :preview writes to a folder. Offering :test
    # here let the panel's own "send a test email" button report success having
    # reached no network at all.
    #
    # Derived from the same question the panel asks -- Adapters::Base.provider?
    # -- rather than from a list of names, because the list this replaced was
    # already out of date the day :preview was added.
    it "describes every provider the registry knows, and no others" do
      expected = SparrowMail.registry.names.select { |name| SparrowMail.registry.fetch(name).provider? }

      expect(described_class.all.map(&:name)).to eq(expected)
    end

    it "withholds the adapters that send to nobody" do
      expect(described_class.all.map(&:name)).not_to include(:test, :preview)
    end

    # Nil would hide it; a Choice that says it is not a provider lets the panel
    # decide. An adapter whose gem is missing is still a provider, which is why
    # this is asked rather than inferred from being listed.
    it "still resolves them by name, for an application that chose one on purpose" do
      expect(described_class.find(:preview)).not_to be_nil
      expect(described_class.find(:preview)).not_to be_provider
    end

    it "takes each adapter's fields from that adapter, required ones first" do
      described_class.all.each do |choice|
        klass = SparrowMail.registry.fetch(choice.name)

        expect(choice.fields.map(&:name))
          .to eq(klass.required_settings + klass.fallback_settings + klass.optional_settings)
      end
    end

    it "says of each field how much the adapter needs it" do
      described_class.all.each do |choice|
        klass = SparrowMail.registry.fetch(choice.name)
        by_kind = choice.fields.group_by(&:kind).transform_values { |fields| fields.map(&:name) }

        expect(by_kind.fetch(:required, [])).to eq(klass.required_settings)
        expect(by_kind.fetch(:fallback, [])).to eq(klass.fallback_settings)
        expect(by_kind.fetch(:optional, [])).to eq(klass.optional_settings)
      end
    end

    # The mark is what tells a developer they can stop. A setting the adapter
    # finds elsewhere when the box is blank is not one they can stop at, so
    # it is not optional, whatever the construction-time check says.
    it "marks as optional only the fields an adapter has no need of" do
      described_class.all.each do |choice|
        klass = SparrowMail.registry.fetch(choice.name)

        expect(choice.fields.select(&:optional?).map(&:name)).to eq(klass.optional_settings)
        expect(choice.fields.select(&:required?).map(&:name)).to eq(klass.required_settings)
      end
    end

    it "takes each adapter's sending identity from that adapter too" do
      # Which settings constitute an identity is the adapter's answer, not the
      # panel's: Mailgun's is the key and the sending domain, SMTP's is the
      # relay and the login. The panel repeats it back when it explains that
      # two streams would share a reputation.
      described_class.all.each do |choice|
        expect(choice.identity_fields.map(&:name))
          .to eq(SparrowMail.registry.fetch(choice.name).identity_settings)
      end
    end

    it "says which adapters have a reputation to lose" do
      by_name = described_class.all.to_h { |choice| [choice.name, choice.reputation_bearing?] }

      by_name.each_key do |name|
        expect(by_name[name]).to eq(SparrowMail.registry.fetch(name).reputation_bearing?)
      end
    end
  end

  describe ".find" do
    it "returns nil for a name nothing is registered under" do
      expect(described_class.find(:carrier_pigeon)).to be_nil
    end

    it "returns nil rather than guessing at a blank name" do
      expect(described_class.find(nil)).to be_nil
      expect(described_class.find("")).to be_nil
    end

    it "picks up an adapter the application registered itself" do
      # The point of the whole file. An adapter this gem has never heard of
      # arrives on the panel with its own fields, and nothing here changed.
      pigeon = Class.new(SparrowMail::Adapters::Base) do
        adapter_name :carrier_pigeon
        required_settings :loft, :ring_id
      end
      SparrowMail.register_adapter(:carrier_pigeon, pigeon)

      choice = described_class.find(:carrier_pigeon)

      expect(choice.fields.map(&:name)).to eq([:loft, :ring_id])
      expect(choice.fields.map(&:label)).to eq(["Loft", "Ring ID"])
    end

    # The same argument, for everything a field carries beyond its name. An
    # adapter that says which values a setting may take, or what a setting
    # is, gets a dropdown and a sentence on the panel without the panel
    # knowing the adapter exists.
    it "passes through what an adapter says about each of its settings" do
      pigeon = Class.new(SparrowMail::Adapters::Base) do
        adapter_name :homing_pigeon
        required_settings :loft
        fallback_settings :handler
        optional_settings :ring_id

        def self.setting_choices(name)
          [["north", "North loft"], ["south", "South loft"]] if name == :loft
        end

        def self.setting_hint(name)
          case name
          when :handler then "Whoever is on duty, if this is blank."
          when :ring_id then "Stamped on the bird's leg."
          end
        end
      end
      SparrowMail.register_adapter(:homing_pigeon, pigeon)

      loft, handler, ring = described_class.find(:homing_pigeon).fields

      expect(loft).to be_required
      expect(loft).to be_choices
      expect(loft.choices).to eq([["north", "North loft"], ["south", "South loft"]])
      expect(loft.hint).to be_nil

      expect(handler.kind).to eq(:fallback)
      expect(handler).not_to be_required
      expect(handler).not_to be_optional
      expect(handler.hint).to eq("Whoever is on duty, if this is blank.")

      expect(ring).to be_optional
      expect(ring).not_to be_choices
      expect(ring.hint).to eq("Stamped on the bird's leg.")
    end

    it "refuses a kind of need it does not have a word for" do
      expect { SparrowMail::Console::Adapters::Field.new(:loft, kind: :whenever) }
        .to raise_error(ArgumentError, /whenever/)
    end

    # A plain adapter says nothing about its settings, and the panel renders
    # a required text box for each. That is the whole of what an adapter has
    # to do, and the reason the base class answers nil for both questions.
    it "asks nothing more of an adapter that only names its settings" do
      described_class.find(:postmark).fields.each do |field|
        expect(field).to be_required
        expect(field).not_to be_choices
        expect(field.hint).to be_nil
      end
    end
  end

  describe ".describe, when the adapter's gem is missing" do
    before do
      allow(SparrowMail.registry).to receive(:fetch).and_call_original
      allow(SparrowMail.registry).to receive(:fetch).with(:ses).and_raise(
        SparrowMail::ConfigurationError, "the ses adapter needs a gem that is not installed"
      )
    end

    it "reports it as unavailable instead of raising" do
      choice = described_class.describe(:ses)

      expect(choice).not_to be_available
      expect(choice.unavailable_reason).to include("not installed")
    end

    it "keeps it in the list, so the page can say why it cannot be chosen" do
      expect(described_class.all.map(&:name)).to include(:ses)
    end

    it "gives it no fields to fill in" do
      expect(described_class.describe(:ses).fields).to be_empty
    end
  end

  describe SparrowMail::Console::Adapters::Field do
    def label_for(name)
      described_class.new(name).label
    end

    it "reads a setting name as words" do
      expect(label_for(:domain)).to eq("Domain")
      expect(label_for(:default_from)).to eq("Default from")
    end

    it "keeps an acronym an acronym" do
      expect(label_for(:api_key)).to eq("API key")
      expect(label_for(:smtp_url)).to eq("SMTP URL")
    end

    it "treats a name that looks like a secret as one, the way sparrow_ui does" do
      expect(described_class.new(:api_key)).to be_secret
      expect(described_class.new(:webhook_token)).to be_secret
      expect(described_class.new(:domain)).not_to be_secret
    end

    # There was an `input_type` here answering "password" or "text". The panel
    # renders a secret through sparrow_ui's field partial now -- a text box
    # masked in CSS, because `type="password"` is what makes a browser offer to
    # save an API key into the developer's password manager. `secret?` above is
    # the whole of what this class still decides.
  end

  # The panel shows brands, and a brand is not the registry key title-cased:
  # `sendlayer` is SendLayer and `ses` is Amazon SES. Each adapter says how it
  # is spelled, so there is still no list of provider names in the console.
  describe "the name shown to a person" do
    it "asks each adapter how it spells itself" do
      SparrowMail.registry.names.each do |name|
        next unless (choice = SparrowMail::Console::Adapters.find(name))&.available?

        expect(choice.display_name).to eq(SparrowMail.registry.fetch(name).display_name)
      end
    end

    it "is never the bare registry key for an adapter we ship" do
      # Not an assertion about any particular brand -- an assertion that every
      # adapter was actually given one. A new adapter that forgets fails here.
      shipped = SparrowMail.registry.names.filter_map { |n| SparrowMail::Console::Adapters.find(n) }

      shipped.select(&:available?).each do |choice|
        expect(choice.display_name).not_to eq(choice.name.to_s),
          "#{choice.name} has no display_name of its own"
      end
    end

    it "still knows the brand of an adapter whose gem is missing" do
      # SES needs the AWS SDK, so its class may never define and cannot be
      # asked. The registry keeps a fallback for that case; listing it as `ses`
      # would read like something is broken.
      expect(SparrowMail.registry.display_name_for(:ses)).to eq("Amazon SES")
    end

    it "keeps the registry's fallback and the class's own answer in step" do
      # Two places name the same brand -- the class, and the registry entry
      # that stands in when the class cannot load. This is what stops them
      # drifting: they must agree wherever both can be read.
      SparrowMail::BUILT_IN_ADAPTERS.each_key do |name|
        klass = begin
          SparrowMail.registry.fetch(name)
        rescue SparrowMail::ConfigurationError
          next
        end

        expect(SparrowMail.registry.display_name_for(name)).to eq(klass.display_name),
          "#{name}: registry says #{SparrowMail.registry.display_name_for(name).inspect}, " \
          "the class says #{klass.display_name.inspect}"
      end
    end

    it "falls back to the key when nothing anywhere said" do
      choice = SparrowMail::Console::Adapters::Choice.new(name: :nameless, unavailable_reason: "no gem")

      expect(choice.display_name).to eq("nameless")
    end

    it "title-cases the key for an adapter that never said" do
      anonymous = Class.new(SparrowMail::Adapters::Base) { adapter_name :my_provider }

      expect(anonymous.display_name).to eq("My Provider")
    end
  end
end
