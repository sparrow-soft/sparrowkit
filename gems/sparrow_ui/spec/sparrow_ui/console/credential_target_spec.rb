# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "securerandom"

TARGET_NAMES = %w[development production].freeze

RSpec.describe SparrowUi::Console::Settings do
  around do |example|
    originals = TARGET_NAMES.to_h do |name|
      target = described_class.resolve_target(name)
      [name, [file_contents(target.content_path), file_contents(target.key_path)]]
    end

    previous_master_key = ENV.delete("RAILS_MASTER_KEY")
    example.run
  ensure
    if previous_master_key.nil?
      ENV.delete("RAILS_MASTER_KEY")
    else
      ENV["RAILS_MASTER_KEY"] = previous_master_key
    end
    originals.each do |name, (content, key)|
      target = described_class.resolve_target(name)
      restore_file(target.content_path, content)
      restore_file(target.key_path, key)
    end
  end

  def file_contents(path)
    path.binread if path.exist?
  end

  def restore_file(path, contents)
    if contents.nil?
      FileUtils.rm_f(path)
    else
      FileUtils.mkdir_p(path.dirname)
      path.binwrite(contents)
    end
  end

  def write_target(name, tree)
    target = described_class.resolve_target(name)
    FileUtils.mkdir_p(target.key_path.dirname)
    target.key_path.binwrite(ActiveSupport::EncryptedFile.generate_key)

    described_class::TargetConfiguration.new(
      config_path: target.content_path,
      key_path: target.key_path,
      env_key: "RAILS_MASTER_KEY",
      raise_if_missing_key: false
    ).write(described_class.deep_stringify(tree).to_yaml)
  end

  def with_target(name, &)
    described_class.with_target(described_class.resolve_target(name), &)
  end

  def checksum(name)
    target = described_class.resolve_target(name)
    [file_contents(target.content_path), file_contents(target.key_path)]
  end

  def with_master_key(value)
    previous = ENV["RAILS_MASTER_KEY"]
    value.nil? ? ENV.delete("RAILS_MASTER_KEY") : ENV["RAILS_MASTER_KEY"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("RAILS_MASTER_KEY") : ENV["RAILS_MASTER_KEY"] = previous
  end

  before do
    write_target("development", {mail: {adapter: "development"}})
    write_target("production", {mail: {adapter: "production"}})
  end

  it "maps only the two supported string targets" do
    expect(described_class.resolve_target("development")&.name).to eq("development")
    expect(described_class.resolve_target("production")&.name).to eq("production")

    [nil, "", "staging", :development, ["development"], {target: "development"}].each do |value|
      expect(described_class.resolve_target(value)).to be_nil
    end
  end

  it "keeps selected target reads and writes isolated" do
    with_target("development") do
      expect(described_class.read(:mail)).to eq(adapter: "development")
      described_class.write(:mail, {adapter: "development-updated"})
    end

    with_target("production") do
      expect(described_class.read(:mail)).to eq(adapter: "production")
    end
  end

  it "masks a selected target's stored secret without returning it" do
    secret = SecureRandom.hex(24)
    with_target("production") { described_class.write(:mail, {api_key: secret}) }

    with_target("production") do
      masked = described_class.for_display(:mail).fetch(:api_key)
      expect(masked).to include(secret: true, set: true)
      expect(masked[:hint]).to eq(secret[-4..])
    end
  end

  it "preserves a blank secret in its selected target" do
    secret = SecureRandom.hex(24)
    with_target("development") do
      described_class.write(:mail, {api_key: secret})
      described_class.write(:mail, {api_key: ""})
      expect(described_class.for_display(:mail).dig(:api_key, :set)).to be(true)
    end
  end

  it "does not write either store when the selected key is missing" do
    before_development = checksum("development")
    before_production = checksum("production")
    target = described_class.resolve_target("development")
    FileUtils.rm_f(target.key_path)

    with_target("development") do
      expect { described_class.write(:mail, {adapter: "changed"}) }
        .to raise_error(described_class::NotWritable, /Development credentials are unavailable/)
    end

    expect(checksum("development").first).to eq(before_development.first)
    expect(checksum("production")).to eq(before_production)
  end

  it "reads and writes a selected target with RAILS_MASTER_KEY and no key file" do
    target = described_class.resolve_target("development")
    master_key = target.key_path.binread.strip
    FileUtils.rm_f(target.key_path)

    with_master_key(master_key) do
      with_target("development") do
        expect(described_class.read(:mail)).to eq(adapter: "development")
        described_class.write(:mail, {adapter: "development-through-environment"})
        expect(described_class.read(:mail)).to eq(adapter: "development-through-environment")
      end
    end
  end

  it "uses RAILS_MASTER_KEY before a selected target key file" do
    target = described_class.resolve_target("development")
    environment_key = ActiveSupport::EncryptedFile.generate_key
    expect(target.key_path.binread.strip).not_to eq(environment_key)

    with_master_key(environment_key) do
      described_class::TargetConfiguration.new(
        config_path: target.content_path,
        key_path: target.key_path,
        env_key: "RAILS_MASTER_KEY",
        raise_if_missing_key: false
      ).write({mail: {adapter: "environment-precedence"}}.to_yaml)

      with_target("development") do
        expect(described_class.read(:mail)).to eq(adapter: "environment-precedence")
      end
    end
  end

  it "does not write either store when selected ciphertext is invalid" do
    target = described_class.resolve_target("development")
    target.content_path.binwrite("invalid encrypted content")
    before_development = checksum("development")
    before_production = checksum("production")

    with_target("development") do
      expect { described_class.write(:mail, {adapter: "changed"}) }
        .to raise_error(described_class::NotWritable, /Development credentials are unavailable/)
    end

    expect(checksum("development")).to eq(before_development)
    expect(checksum("production")).to eq(before_production)
  end

  it "does not write either store when encryption fails" do
    before_development = checksum("development")
    before_production = checksum("production")
    allow(described_class::TargetConfiguration).to receive(:new).and_raise(Errno::EACCES)

    with_target("development") do
      expect { described_class.write(:mail, {adapter: "changed"}) }
        .to raise_error(described_class::NotWritable, /Development credentials are unavailable/)
    end

    expect(checksum("development")).to eq(before_development)
    expect(checksum("production")).to eq(before_production)
  end
end
