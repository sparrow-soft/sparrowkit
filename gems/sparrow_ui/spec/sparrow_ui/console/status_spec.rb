# frozen_string_literal: true

RSpec.describe SparrowUi::Console::Status do
  describe ".from" do
    it "takes the Hash a module can build without knowing this gem exists" do
      status = described_class.from({state: :ready, detail: "Sending through Postmark."})

      expect(status.state).to eq(:ready)
      expect(status.detail).to eq("Sending through Postmark.")
    end

    it "accepts string keys and a string state, because credentials round-trip through YAML" do
      expect(described_class.from({"state" => "attention", "detail" => "x"}).state).to eq(:attention)
    end

    it "passes a Status through untouched" do
      original = described_class.ready("fine")

      expect(described_class.from(original)).to equal(original)
    end

    it "reads an unrecognised state as unknown rather than raising" do
      # The caller is rendering three modules' cards on one page. A module
      # returning nonsense should cost that module its badge, not the page.
      expect(described_class.from({state: :on_fire}).state).to eq(:unknown)
    end

    it "reads something that is not a Hash at all as unknown" do
      expect(described_class.from(nil).state).to eq(:unknown)
      expect(described_class.from("ready").state).to eq(:unknown)
    end
  end

  it "labels every state in words, so colour is never the only signal" do
    # WCAG 1.4.1. Three cards distinguished by hue alone are one card to a
    # reader who cannot separate amber from green.
    labels = described_class::STATES.map { |state| described_class.new(state: state).label }

    expect(labels).to all(be_a(String))
    expect(labels.uniq.size).to eq(described_class::STATES.size)
  end
end
