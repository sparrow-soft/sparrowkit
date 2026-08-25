# frozen_string_literal: true

RSpec.describe SparrowMail::Registry do
  subject(:registry) { described_class.new }

  describe "registering a class directly" do
    it "returns it" do
      registry.register(:counting, FakeAdapters::Counting)

      expect(registry.fetch(:counting)).to eq(FakeAdapters::Counting)
    end

    it "accepts a string name" do
      registry.register("counting", FakeAdapters::Counting)

      expect(registry.fetch(:counting)).to eq(FakeAdapters::Counting)
    end

    it "can be removed again" do
      registry.register(:counting, FakeAdapters::Counting)
      registry.delete(:counting)

      expect(registry.key?(:counting)).to be(false)
    end
  end

  describe "lazy registration" do
    it "requires the file and resolves the constant on first use" do
      registry.register_lazy(:test, "sparrow_mail/adapters/test", "SparrowMail::Adapters::Test")

      expect(registry.fetch(:test)).to eq(SparrowMail::Adapters::Test)
    end

    it "resolves only once" do
      registry.register_lazy(:test, "sparrow_mail/adapters/test", "SparrowMail::Adapters::Test")

      expect(registry.fetch(:test)).to be(registry.fetch(:test))
    end

    # This is why adapters are registered lazily: an application on Postmark
    # should not load the AWS SDK, and one without it installed should get a
    # sentence explaining what to add rather than a bare LoadError.
    it "explains which gem is missing when the adapter's dependency is absent" do
      registry.register_lazy(:pigeon, "no_such_gem_anywhere", "NoSuchGem")

      expect { registry.fetch(:pigeon) }
        .to raise_error(SparrowMail::ConfigurationError, /no_such_gem_anywhere/)
    end
  end

  describe "an unknown adapter" do
    it "names what was asked for" do
      expect { registry.fetch(:carrier_pigeon) }
        .to raise_error(SparrowMail::ConfigurationError, /carrier_pigeon/)
    end

    it "lists the adapters that do exist" do
      registry.register(:test, SparrowMail::Adapters::Test)
      registry.register(:smtp, SparrowMail::Adapters::SMTP)

      # Registration order, which is what #names now reports: the order a
      # developer is offered them in is chosen rather than alphabetical, and
      # this message is the same list.
      expect { registry.fetch(:nope) }
        .to raise_error(SparrowMail::ConfigurationError, /test, smtp/)
    end

    it "says how to register a third-party adapter" do
      expect { registry.fetch(:nope) }
        .to raise_error(SparrowMail::ConfigurationError, /register_adapter/)
    end
  end

  describe "the built-in registry" do
    it "knows every adapter that ships with the gem" do
      expect(SparrowMail.registry.names)
        .to contain_exactly(:mailgun, :postmark, :sendgrid, :sendlayer, :ses, :smtp, :test, :preview)
    end

    it "offers them in the order the gem declares, not alphabetically" do
      # The order is the one a developer is shown. Sorting would put Mailgun
      # first for no reason a reader could name, and would bury the two that
      # are not hosted providers among the ones that are.
      expect(SparrowMail.registry.names).to eq(SparrowMail::BUILT_IN_ADAPTERS.keys)
    end

    it "puts what is not a hosted provider last" do
      names = SparrowMail.registry.names

      expect(names.last(3)).to eq(%i[smtp test preview])
    end

    # The same question the console asks to build its dropdown, asked here so
    # that an adapter arriving without an opinion is caught in the gem rather
    # than by appearing on somebody's settings page.
    it "knows which of them are a way of sending mail to somebody" do
      offered, withheld = SparrowMail::BUILT_IN_ADAPTERS.keys
        .partition { |name| SparrowMail.registry.fetch(name).provider? }

      expect(withheld).to eq(%i[test preview])
      expect(offered).to include(:postmark, :smtp)
    end

    it "registers each one under the name its class reports" do
      SparrowMail::BUILT_IN_ADAPTERS.each_key do |name|
        expect(SparrowMail.registry.fetch(name).adapter_name).to eq(name)
      end
    end

    it "gives every adapter a distinct name" do
      names = SparrowMail::BUILT_IN_ADAPTERS.keys.map { |n| SparrowMail.registry.fetch(n) }

      expect(names.uniq.size).to eq(names.size)
    end
  end
end
