# frozen_string_literal: true

# One page. Everything sparrow_mail asks a developer for fits on it, and a
# second route would only be somewhere for a setting to hide.
#
# Paths are relative to wherever sparrow_ui mounted this engine, and the
# controller is written WITHOUT the `sparrow_mail/` prefix: isolate_namespace
# sets a default module scope of "sparrow_mail" for this route set, and
# ActionDispatch joins that to whatever is written here without checking for a
# repeat. Spell it out and the route resolves SparrowMail::SparrowMail::...
SparrowMail::ConsoleEngine.routes.draw do
  root to: "console/sparrowkit#show"
  patch "/", to: "console/sparrowkit#update", as: :sparrowkit

  # The one exception to "one page": a POST that performs a send rather than
  # storing a setting. It lives under the same panel because the question it
  # answers -- do these settings actually deliver mail? -- is asked standing
  # in front of them.
  post "test", to: "console/sparrowkit#test_send", as: :test_send

  # And a way to empty the folder mail goes to while no provider is chosen.
  # A page that only grows is a page nobody can find today's message on.
  delete "mailbox", to: "console/sparrowkit#clear_mailbox", as: :mailbox
end
