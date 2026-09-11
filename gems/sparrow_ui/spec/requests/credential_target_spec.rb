# frozen_string_literal: true

require "rails_helper"
require "fileutils"
require "securerandom"
require "stringio"

RSpec.describe "credential target selection", type: :request do
  before { allow(Rails.env).to receive(:development?).and_return(true) }

  around do |example|
    target = SparrowUi::Console::Settings.resolve_target("development")
    original_content = target.content_path.binread if target.content_path.exist?
    original_key = target.key_path.binread if target.key_path.exist?
    previous_master_key = ENV.delete("RAILS_MASTER_KEY")
    example.run
  ensure
    restore_target_file(target.content_path, original_content)
    restore_target_file(target.key_path, original_key)
    previous_master_key.nil? ? ENV.delete("RAILS_MASTER_KEY") : ENV["RAILS_MASTER_KEY"] = previous_master_key
  end

  def open_console(params = {})
    get "/sparrowkit", params:, env: {"REMOTE_ADDR" => "127.0.0.1"}
  end

  def prepare_development_target
    target = SparrowUi::Console::Settings.resolve_target("development")
    FileUtils.mkdir_p(target.key_path.dirname)
    target.key_path.binwrite(ActiveSupport::EncryptedFile.generate_key)
    SparrowUi::Console::Settings::TargetConfiguration.new(
      config_path: target.content_path,
      key_path: target.key_path,
      env_key: "RAILS_MASTER_KEY",
      raise_if_missing_key: false
    ).write({"secret_key_base" => "dummy" * 16}.to_yaml)
  end

  def restore_target_file(path, contents)
    if contents.nil?
      FileUtils.rm_f(path)
    else
      FileUtils.mkdir_p(path.dirname)
      path.binwrite(contents)
    end
  end

  def capture_request_log
    log = StringIO.new
    logger = ActiveSupport::Logger.new(log)
    previous_rails_logger = Rails.logger
    previous_config_logger = Rails.application.config.logger
    previous_controller_logger = ActionController::Base.logger
    Rails.logger = logger
    Rails.application.config.logger = logger
    ActionController::Base.logger = logger
    yield log
  ensure
    Rails.logger = previous_rails_logger
    Rails.application.config.logger = previous_config_logger
    ActionController::Base.logger = previous_controller_logger
  end

  it "rejects a missing target without opening a credential store" do
    allow(SparrowUi::Console::Settings).to receive(:store).and_raise("must not open")

    open_console

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to eq("Choose a supported credential target.")
  end

  it "rejects a forged target without echoing it" do
    open_console(credential_target: "not-a-target")

    expect(response).to have_http_status(:unprocessable_entity)
    expect(response.body).to eq("Choose a supported credential target.")
    expect(response.body).not_to include("not-a-target")
  end

  it "persists a valid selection for target-free navigation" do
    open_console(credential_target: "development")
    expect(response).to have_http_status(:ok)

    open_console
    expect(response).to have_http_status(:ok)
  end

  it "filters a submitted credential from the response, flash, and request log" do
    prepare_development_target
    canary = SecureRandom.hex(24)

    capture_request_log do |log|
      patch "/sparrowkit", params: {
        credential_target: "development",
        app_url: "",
        api_key: canary
      }, env: {"REMOTE_ADDR" => "127.0.0.1"}

      expect(response).to have_http_status(:found)
      expect(log.string).to include("[FILTERED]")
      expect(log.string).not_to include(canary)
    end

    expect(response.body).not_to include(canary)
    expect(flash[:notice]).not_to include(canary)
  end
end
