# frozen_string_literal: true

RSpec.describe SparrowPay do
  it "carries the lockstep version from the repository root VERSION file" do
    root_version = File.read(File.expand_path("../../../VERSION", __dir__)).strip

    expect(described_class::VERSION).to eq(root_version)
  end
end
