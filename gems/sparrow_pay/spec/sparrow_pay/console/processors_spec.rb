# frozen_string_literal: true

require "rails_helper"

# The panel's field list, derived from Pay rather than written down.
#
# Worth testing directly because the derivation is the load-bearing idea: if it
# stops matching what Pay actually reads, the panel quietly stops offering a
# field, the developer never enters it, and the failure arrives much later as a
# webhook that does not verify.
RSpec.describe SparrowPay::Console::Processors do
  it "offers every processor Pay is willing to run" do
    expect(described_class.names).to match_array(Pay.enabled_processors.map(&:to_sym))
  end

  it "offers processors that are not set up yet, which on this panel is the point" do
    # Filtering by Pay's `enabled?` would hide every processor whose keys are
    # missing -- which is all of them, and is the reason the developer came.
    expect(described_class.names).not_to be_empty
  end

  # The proof that the derivation is right, checked against Pay's own source
  # rather than against a list here -- a list would just be the thing this code
  # exists to avoid, restated in a spec.
  it "derives exactly the settings Pay looks up in credentials" do
    described_class.names.each do |name|
      source_file = Pay::Engine.root.join("lib", "pay", "#{name}.rb")
      next unless source_file.exist?

      looked_up = source_file.read.scan(/find_value_by_name\(:#{name}, :(\w+)\)/).flatten.map(&:to_sym).uniq.sort

      # Sorted on both sides, because what this example promises is WHICH
      # fields, not what order they appear in. The order is a presentation
      # rule -- required before optional -- and it has an example of its own
      # below; comparing the two claims in one assertion made a change to the
      # running order look like the panel had lost a field.
      expect(described_class.fields_for(name).sort).to eq(looked_up),
        "#{name}: panel offers #{described_class.fields_for(name).inspect}, Pay reads #{looked_up.inspect}"
    end
  end

  # The card used to open with `context`, the field almost nobody needs, above
  # the two they came for -- because alphabetical was the only order there was.
  it "puts the fields a developer must fill in above the ones they may skip" do
    described_class.names.each do |name|
      fields = described_class.fields_for(name)
      next if fields.empty?

      required, optional = fields.partition { |field| !described_class.optional?(field) }

      expect(fields).to eq(required + optional),
        "#{name}: #{fields.inspect} mixes optional fields in among the required ones"
      expect(required).to eq(required.sort)
      expect(optional).to eq(optional.sort)
    end
  end

  it "returns no fields for something Pay does not run" do
    expect(described_class.fields_for(:not_a_processor)).to eq([])
  end

  it "does not mistake a method taking a required keyword for a setting" do
    # `parameters`, not `arity`: a method whose only argument is a required
    # keyword reports an arity of 0, and would otherwise arrive on the page as
    # a text box that saves nothing.
    described_class.names.each do |name|
      mod = described_class.module_for(name)
      next if mod.nil?

      described_class.fields_for(name).each do |field|
        expect(mod.method(field).parameters).to be_empty
      end
    end
  end

  it "writes a processor's key the way a person would read it" do
    expect(described_class.label_for(:paddle_billing)).to eq("Paddle Billing")
    expect(described_class.label_for(:signing_secret)).to eq("Signing Secret")
  end
end
