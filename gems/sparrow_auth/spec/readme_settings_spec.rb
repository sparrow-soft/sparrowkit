require "rails_helper"

# The README's settings tables, checked against the real configuration object.
#
# They had fallen six settings behind before anybody noticed, and all six were
# from the three most recent phases — which is exactly when a table is least
# likely to be re-read and most likely to be wrong.
RSpec.describe "the README's settings tables" do
  it "covers every setting the configuration object has" do
    readme = SparrowAuth::Engine.root.join("README.md").read

    settings = SparrowAuth::Configuration.instance_methods(false)
      .map(&:to_s).select { |n| n.end_with?("=") }.map { |n| n.delete_suffix("=") }

    missing = settings.reject { |s| readme.include?("`#{s}`") }

    expect(missing).to be_empty,
      "The README does not document: #{missing.join(", ")}."
  end

  # And the other direction, which nothing checked.
  #
  # The table went on documenting `api_audiences`, `api_token_secret` and
  # `staff_step_up_within` for two releases after the features they configured
  # were deleted -- a reader could set any of the three, watch nothing happen,
  # and have no way to tell whether they had made a mistake. One-way checking
  # catches a setting that arrives and misses one that leaves, and the second is
  # the harder of the two to notice by reading.
  it "documents nothing the configuration object does not have" do
    readme = SparrowAuth::Engine.root.join("README.md").read

    settings = SparrowAuth::Configuration.instance_methods(false)
      .map(&:to_s).select { |n| n.end_with?("=") }.map { |n| n.delete_suffix("=") }

    # Only the settings tables, found by their header.
    #
    # Scanning every `| \`name\` |` row instead reads the screens table and the
    # roles table as settings, and then reports `viewer` and `passkeys` as
    # settings that do not exist -- which is a failing test that is wrong,
    # which is worse than no test.
    documented = readme.lines.each_with_object([]) do |line, names|
      @in_settings_table = true if line.start_with?("| Setting |")
      @in_settings_table = false if line.strip.empty?
      next unless @in_settings_table

      name = line[/\A\| `([a-z_]+)` \|/, 1]
      names << name if name
    end.uniq

    invented = documented - settings

    expect(invented).to be_empty,
      "The README documents settings that do not exist: #{invented.join(", ")}."
  end
end
