# frozen_string_literal: true

# The console panel's routes.
#
# This said "one page", and that everything the console asks about
# authentication fits on it, and that a second route would only be somewhere
# for a setting to hide. The first two are still true and the rule they were
# protecting still holds: /roles asks for nothing and stores nothing. It is a
# reading of two sources that otherwise cannot be read together — the
# permissions declared in the host's code, and the roles that hold them — and
# a report is not a place a setting can hide.
#
# Named console_routes.rb rather than routes.rb because this gem ships two
# engines from one directory -- see lib/sparrow_auth/console_engine.rb, which
# points this engine's `config/routes.rb` path here so the two do not both
# claim the file the auth engine already owns.
#
# Paths are relative to wherever sparrow_ui mounted this engine, and the
# controller is written WITHOUT the `sparrow_auth/` prefix: isolate_namespace
# sets a default module scope of "sparrow_auth" for this route set, and
# ActionDispatch joins that to whatever is written here without checking for a
# repeat. Spell it out and the route resolves SparrowAuth::SparrowAuth::...
SparrowAuth::ConsoleEngine.routes.draw do
  root to: "console/sparrowkit#show"
  patch "/", to: "console/sparrowkit#update", as: :sparrowkit

  # The development sign-in harness. A POST that establishes a session rather
  # than storing a setting, which is why it is a route of its own rather than
  # another field on the form above.
  #
  # It stores nothing, so the rule this file opens with -- a second route would
  # only be somewhere for a setting to hide -- is not being bent.
  post "sign-in-as", to: "console/sparrowkit#sign_in_as", as: :sign_in_as
end
