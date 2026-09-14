# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "stringio"

RSpec.describe "SparrowUi::Console::Settings.ensure_target_files!" do
  around do |example|
    backups = SparrowUi::Console::Settings::TARGETS.keys.to_h do |name|
      target = SparrowUi::Console::Settings.resolve_target(name)
      [name, [file_or_nil(target.content_path), file_or_nil(target.key_path)]]
    end
    previous_master_key = ENV.delete("RAILS_MASTER_KEY")

    example.run
  ensure
    backups.each do |name, (content, key)|
      target = SparrowUi::Console::Settings.resolve_target(name)
      restore(target.content_path, content)
      restore(target.key_path, key)
    end
    previous_master_key.nil? ? ENV.delete("RAILS_MASTER_KEY") : ENV["RAILS_MASTER_KEY"] = previous_master_key
  end

  def file_or_nil(path)
    path.binread if path.exist?
  end

  def restore(path, contents)
    if contents.nil?
      FileUtils.rm_f(path)
    else
      FileUtils.mkdir_p(path.dirname)
      path.binwrite(contents)
    end
  end

  def remove_all_target_files
    SparrowUi::Console::Settings::TARGETS.each_key do |name|
      target = SparrowUi::Console::Settings.resolve_target(name)
      FileUtils.rm_f(target.content_path)
      FileUtils.rm_f(target.key_path)
    end
  end

  def decrypted(name)
    target = SparrowUi::Console::Settings.resolve_target(name)
    SparrowUi::Console::Settings.with_target(target) { SparrowUi::Console::Settings.all }
  end

  # The real install task wraps this in Sparrowkit::InstallOutput.run, which
  # redirects $stdout into log/sparrowkit-install.log for the same reason:
  # the generators announce every key and file they touch, and that detail
  # belongs in a log nobody has to read, not the terminal -- or, here, the
  # spec run.
  def ensure_target_files!
    original = $stdout
    $stdout = StringIO.new
    SparrowUi::Console::Settings.ensure_target_files!
  ensure
    $stdout = original
  end

  it "creates a credentials file and key for every target that is missing one" do
    remove_all_target_files

    ensure_target_files!

    SparrowUi::Console::Settings::TARGETS.each_key do |name|
      target = SparrowUi::Console::Settings.resolve_target(name)
      expect(target.content_path).to exist
      expect(target.key_path).to exist
    end
  end

  it "writes a real secret_key_base for production but none for development" do
    remove_all_target_files

    ensure_target_files!

    expect(decrypted("development")).not_to have_key(:secret_key_base)
    expect(decrypted("production")).to have_key(:secret_key_base)
  end

  it "leaves an existing target's file untouched rather than overwriting it" do
    target = SparrowUi::Console::Settings.resolve_target("development")
    FileUtils.mkdir_p(target.key_path.dirname)
    target.key_path.binwrite(ActiveSupport::EncryptedFile.generate_key)
    SparrowUi::Console::Settings::TargetConfiguration.new(
      config_path: target.content_path,
      key_path: target.key_path,
      env_key: "RAILS_MASTER_KEY",
      raise_if_missing_key: false
    ).write({"marker" => "already here"}.to_yaml)

    ensure_target_files!

    expect(decrypted("development")).to eq(marker: "already here")
  end
end
