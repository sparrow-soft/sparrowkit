# frozen_string_literal: true

require "fileutils"
require "yaml"

# Real Rails encrypted Development credentials for the console panel's request
# specs, built fresh per example in an ignored directory.
#
# Real ones rather than a stubbed SparrowUi::Console::Settings, because the
# behaviour most worth proving lives inside Settings.write: a blank secret is
# dropped rather than written, so submitting the empty key box the form is
# obliged to render does not erase the stored key. Stub that and the spec proves
# only that the controller calls a method.
#
# This gem's panel writes to TWO top-level keys -- its own settings under
# `sparrow_pay:`, and the processor's keys under its own name where Pay reads
# them -- so `reset!` takes a whole credentials tree.
module ConsoleCredentials
  # A realistic starting point: a Rails application's credentials always carry
  # at least this, and an EMPTY file is not equivalent -- Settings.writable?
  # asks `credentials.present?`, which is false for an empty tree.
  SEED = {"secret_key_base" => "0" * 64}.freeze

  module_function

  def key_path
    Rails.application.config.credentials.key_path.to_s
  end

  def content_path
    Rails.application.config.credentials.content_path.to_s
  end

  # A fresh key and a fresh encrypted file. Anything passed in is merged over
  # the seed, so a spec can start from "this key is already stored".
  def reset!(tree = nil)
    FileUtils.mkdir_p(File.dirname(key_path))
    File.write(key_path, ActiveSupport::EncryptedFile.generate_key)
    FileUtils.rm_f(content_path)
    forget!

    Rails.application.credentials.write(SEED.merge(deep_stringify(tree || {})).to_yaml)
    forget!
  end

  # No master key, which is what a developer sees on a checkout that did not
  # come with one.
  def without_key!
    FileUtils.rm_f(key_path)
    forget!
  end

  # What is actually in the explicit Development target now, decrypted from
  # scratch. The dummy runtime is configured to that target on purpose.
  def stored(*path)
    tree = stored_tree
    path.empty? ? tree : (tree.dig(*path) || {})
  end

  def stored_tree
    forget!
    Rails.application.credentials.config
  end

  # This gem's own settings.
  def stored_pay
    stored(SparrowPay::CREDENTIALS_KEY)
  end

  def forget!
    # Test-fixture cache reset only. Console settings intentionally never
    # resets or reads Rails.application.credentials, because target selection
    # must stay explicit in production code.
    application = Rails.application
    application.remove_instance_variable(:@credentials) if application.instance_variable_defined?(:@credentials)
  end

  def deep_stringify(object)
    case object
    when Hash then object.to_h { |key, value| [key.to_s, deep_stringify(value)] }
    when Array then object.map { |value| deep_stringify(value) }
    else object
    end
  end
end
