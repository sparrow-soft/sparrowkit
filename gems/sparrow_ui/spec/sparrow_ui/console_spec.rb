# frozen_string_literal: true

RSpec.describe SparrowUi::Console do
  # A stand-in for another gem's engine. The registry must not care what this
  # is beyond it being mountable.
  # Mountable, because register refuses anything that is not: config/routes.rb
  # mounts every registered panel, and a fake that cannot answer a request only
  # fails later, from the route set, on whichever seed happens to redraw routes
  # while it is registered.
  let(:fake_engine) { ->(_env) { [200, {"content-type" => "text/plain"}, ["a panel"]] } }

  # Emptied for the example and put back afterwards.
  #
  # Restored, not just cleared, and that is the whole point. The registry is
  # global and filled at boot by whichever gems the dummy app has -- the dummy
  # boots with sparrow_mail, so :mail is registered AND mounted, and the
  # request specs render a real panel page through it. A bare `reset!` in an
  # `after` hook deleted that for every file that ran later, which is an
  # order-dependent failure: green alone, red in the suite, and pointing at
  # the wrong file when it goes.
  around do |example|
    boot_registry = described_class.registry.dup
    described_class.reset!
    example.run
    described_class.reset!
    described_class.registry.merge!(boot_registry)
  end

  it "registers a panel and reports it" do
    described_class.register(key: :auth, name: "Authentication", engine: fake_engine)

    expect(described_class.panels.map(&:name)).to eq(["Authentication"])
  end

  it "gives each panel a path under the mount, derived from its key" do
    described_class.register(key: :mail, name: "Mail", engine: fake_engine)

    expect(described_class.panels.first.path).to eq("/mail")
  end

  it "orders panels by name, so the hub does not reshuffle on boot order" do
    described_class.register(key: :pay, name: "Billing", engine: fake_engine)
    described_class.register(key: :auth, name: "Authentication", engine: fake_engine)

    expect(described_class.panels.map(&:name)).to eq(["Authentication", "Billing"])
  end

  # The order a developer should work through, which is not alphabetical. Mail
  # is first because nothing else finishes without it: an application cannot
  # email a sign-in code until mail sends, so doing authentication first ends
  # at a form that looks like it worked and a message that never arrives.
  it "puts a module with an earlier setup order first, whatever it is called" do
    described_class.register(key: :auth, name: "Authentication", engine: fake_engine, setup_order: 20)
    described_class.register(key: :mail, name: "Mail", engine: fake_engine, setup_order: 10)

    expect(described_class.panels.map(&:name)).to eq(["Mail", "Authentication"])
  end

  it "sorts a module that names no setup order after every module that does" do
    described_class.register(key: :later, name: "Aardvark", engine: fake_engine)
    described_class.register(key: :mail, name: "Mail", engine: fake_engine, setup_order: 10)

    expect(described_class.panels.map(&:name)).to eq(["Mail", "Aardvark"])
  end

  # Not asserted here: that mail, auth and pay ship as 10, 20 and 30. This
  # gem's dummy application loads sparrow_mail and neither of the others, so
  # any check written here could only compare numbers this file had itself
  # written down — a test that passes whether or not the gems agree. The place
  # the three are actually seen together is preview/, which no suite runs.

  it "refuses a duplicate key rather than silently replacing a panel" do
    described_class.register(key: :auth, name: "Authentication", engine: fake_engine)

    expect { described_class.register(key: :auth, name: "Other", engine: fake_engine) }
      .to raise_error(ArgumentError, /already registered/)
  end

  it "refuses a key that would not make a clean path segment" do
    expect { described_class.register(key: "auth/../..", name: "X", engine: fake_engine) }
      .to raise_error(ArgumentError, /key/)
  end

  it "starts empty, so a host with no modules still boots" do
    expect(described_class.panels).to be_empty
  end

  describe "the status a panel reports to the hub" do
    def panel_with(status)
      described_class.register(key: :mail, name: "Mail", engine: fake_engine, status: status)
      described_class.panels.first
    end

    it "coerces whatever the module returns into a Status" do
      expect(panel_with(-> { {state: :ready, detail: "Sending through Postmark."} }).status)
        .to have_attributes(state: :ready, detail: "Sending through Postmark.")
    end

    it "asks again on every call, so a badge cannot outlive the save that changed it" do
      answers = [{state: :unconfigured}, {state: :ready}].each
      panel = panel_with(-> { answers.next })

      expect([panel.status.state, panel.status.state]).to eq([:unconfigured, :ready])
    end

    it "reports unknown for a module that did not offer one" do
      described_class.register(key: :auth, name: "Authentication", engine: fake_engine)

      expect(described_class.panels.first.status.state).to eq(:unknown)
    end

    it "survives a module whose check raises, because the hub is three modules' front page" do
      # A half-configured module is exactly when a status check is most likely
      # to blow up, and exactly when the developer most needs this page to
      # render. One card says Unknown; the other two still work.
      panel = panel_with(-> { raise IOError, "credentials are unreadable" })

      expect(panel.status).to have_attributes(state: :unknown, detail: /IOError/)
    end
  end

  describe "documentation links" do
    it "falls back to the documented convention when a module names no URL" do
      described_class.register(key: :mail, name: "Mail", engine: fake_engine)

      expect(described_class.panels.first.docs_url).to eq("#{described_class::DOCS_URL}/mail/")
    end

    it "lets a module name its own" do
      described_class.register(key: :mail, name: "Mail", engine: fake_engine, docs_url: "https://example.test/m")

      expect(described_class.panels.first.docs_url).to eq("https://example.test/m")
    end
  end
end
