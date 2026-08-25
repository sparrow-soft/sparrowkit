# frozen_string_literal: true

# Nothing.
#
# SparrowKit serves no end-user pages. The screens your customers look at carry
# your navigation, your styling and your words, so they are yours to write --
# against the models in this gem, which is all it offers.
#
# What used to be here: sign-in, the emailed-code pages, passkey management,
# active sessions, connected providers, invitation acceptance, and a member
# admin area. There is no generator that writes them for you either; every one
# of them is a page you write, wired to the same models.
#
# Rodauth's own routes -- login, logout, create-account, verify-account, the
# passkey ceremony -- are unaffected by this file. They are served by Roda
# middleware above the Rails router, at `config.path_prefix`, and are not part
# of any route set.
SparrowAuth::Engine.routes.draw do
end
