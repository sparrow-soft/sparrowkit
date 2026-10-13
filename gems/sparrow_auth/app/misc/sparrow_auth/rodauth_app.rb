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
    end
  end
end
