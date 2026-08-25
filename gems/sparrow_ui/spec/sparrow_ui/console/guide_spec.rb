# frozen_string_literal: true

RSpec.describe SparrowUi::Console::Guide do
  describe ".from" do
    it "takes the Hash a module can build without knowing this gem exists" do
      guide = described_class.from({steps: ["bin/rails db:migrate"], brief: "Some prose."})

      expect(guide.steps).to eq(["bin/rails db:migrate"])
      expect(guide.brief).to eq("Some prose.")
    end

    it "accepts string keys" do
      expect(described_class.from({"brief" => "x"}).brief).to eq("x")
    end

    it "drops empty steps rather than rendering a blank code block" do
      expect(described_class.from({steps: ["a", "", nil]}).steps).to eq(["a"])
    end

    it "reads anything that is not a Hash as nothing to say" do
      expect(described_class.from(nil)).not_to be_any
      expect(described_class.from("steps")).not_to be_any
    end
  end

  it "reports having nothing when a module offers no guide" do
    expect(described_class.none).not_to be_any
  end
end

RSpec.describe "a panel's guide" do
  # Mountable, because register refuses anything that is not: config/routes.rb
  # mounts every registered panel, and a fake that cannot answer a request only
  # fails later, from the route set, on whichever seed happens to redraw routes
  # while it is registered.
  let(:fake_engine) { ->(_env) { [200, {"content-type" => "text/plain"}, ["a panel"]] } }

  # Restored rather than merely cleared -- see the note in console_spec.rb. The
  # registry is filled at boot and the request specs render through it.
  around do |example|
    boot_registry = SparrowUi::Console.registry.dup
    SparrowUi::Console.reset!
    example.run
    SparrowUi::Console.reset!
    SparrowUi::Console.registry.merge!(boot_registry)
  end

  def panel_with(guide)
    SparrowUi::Console.register(key: :mail, name: "Mail", engine: fake_engine, guide: guide)
    SparrowUi::Console.panels.first
  end

  it "asks the module on every call, so the prompt cannot describe a stale save" do
    answers = [{brief: "before"}, {brief: "after"}].each
    panel = panel_with(-> { answers.next })

    expect([panel.guide.brief, panel.guide.brief]).to eq(["before", "after"])
  end

  it "has nothing to say for a module that offered none" do
    SparrowUi::Console.register(key: :auth, name: "Authentication", engine: fake_engine)

    expect(SparrowUi::Console.panels.first.guide).not_to be_any
  end

  it "survives a module whose guide raises" do
    # This renders on the page whose whole job is telling somebody what to do
    # next. One module failing must not take that page down.
    panel = panel_with(-> { raise IOError })

    expect(panel.guide.steps).to be_empty
  end

  # It used to return Guide.none, which is also what a module with nothing to
  # say returns -- so a raising module and a quiet one were the same thing on
  # screen. The guide is the text a developer pastes into an assistant; its
  # silence is the kind nobody investigates.
  it "says a module could not describe itself, rather than saying nothing" do
    panel = panel_with(-> { raise IOError })

    expect(panel.guide.brief).to include("IOError")
  end
end
