# frozen_string_literal: true

module SparrowAuth
  # The Roda application Rodauth runs inside, shipped by the engine rather than
  # generated into the host. This is the packaging property that made Rodauth
  # the right choice over Devise: the whole auth configuration is one object a
  # gem can own, instead of model mixins, initializers and controller filters a
  # host has to assemble correctly and keep assembled.
  class RodauthApp < Rodauth::Rails::App
    configure RodauthMain

    # The Turnstile widget's script, served beside Rodauth's own scripts so an
    # application needs no bundler configuration to get it. See
    # SparrowAuth::Turnstile.widget.
    TURNSTILE_JS = File.read(
      File.expand_path("../../javascript/sparrow_auth/turnstile.js", __dir__)
    ).freeze

    route do |r|
      r.rodauth
      rodauth.load_memory if rodauth.features.include?(:remember)

      r.get SparrowAuth::Turnstile.script_path.delete_prefix("/") do
        response["content-type"] = "text/javascript"
        TURNSTILE_JS
      end

      # The passkey the last sign-in attempt offered that no account has, once,
      # for the sign-in screen's script to tell the device about. Read from the
      # session and forgotten. See RodauthMain#sparrow_auth_note_unknown_passkey.
      r.get "#{SparrowAuth.config.path_prefix.delete_prefix("/")}/unknown-passkey" do
        id = r.env["rack.session"]&.delete(SparrowAuth::RodauthMain::UNKNOWN_PASSKEY)
        id = nil unless id.is_a?(String) && id.match?(SparrowAuth::RodauthMain::CREDENTIAL_ID)
        response["content-type"] = "application/json"
        response["cache-control"] = "no-store"
        JSON.generate(credential_id: id)
      end
    end
  end
end
