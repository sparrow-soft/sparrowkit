# frozen_string_literal: true

module SparrowAuth
  # The Roda application Rodauth runs inside, shipped by the engine rather than
  # generated into the host. This is the packaging property that made Rodauth
  # the right choice over Devise: the whole auth configuration is one object a
  # gem can own, instead of model mixins, initializers and controller filters a
  # host has to assemble correctly and keep assembled.
  class RodauthApp < Rodauth::Rails::App
    configure RodauthMain

    route do |r|
      r.rodauth
      rodauth.load_memory if rodauth.features.include?(:remember)
    end
  end
end
