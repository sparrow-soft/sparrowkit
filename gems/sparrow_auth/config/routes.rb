# frozen_string_literal: true

# Nothing.
#
# SparrowKit serves no end-user pages. The screens your customers look at carry
# your navigation, your styling and your words, so they are yours -- generated
# into your application by `rails generate sparrowkit:screens` and owned by you
# from the moment they land.
#
# What used to be here: sign-in, the emailed-code pages, passkey management,
# active sessions, connected providers, invitation acceptance, and a member
# admin area. Every one of them is something the generator now writes into your
# app, wired to the same models.
#
# Rodauth's own routes -- login, logout, create-account, verify-account, the
# passkey ceremony -- are unaffected by this file. They are served by Roda
# middleware above the Rails router, at `config.path_prefix`, and are not part
# of any route set.
SparrowAuth::Engine.routes.draw do
end
