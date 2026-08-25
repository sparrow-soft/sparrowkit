# frozen_string_literal: true

Rails.application.routes.draw do
  resources :connections, only: [:index, :destroy]
  get "invitations/:token", to: "invitations#show", as: :invitation
  post "invitations/:token", to: "invitations#accept", as: :accept_invitation
  mount SparrowAuth::Engine => "/auth"

  # The developer console, and the auth control panel sparrow_auth registers
  # with it.
  #
  # ONE mount, at /sparrowkit, with every panel nested below it. The panel used
  # to be mounted directly at /console/auth as well, as a way to exercise it
  # without standing up the hub -- but a sibling mount does not pass through
  # sparrow_ui's engine middleware, so that shortcut also skipped the gate it
  # was relying on someone else to prove.
  #
  # Mounted unconditionally because exercising the panel is part of this dummy's
  # job, and a guard on `Rails.env.development?` would put it out of reach of
  # the request specs, which run in the test environment. A real host mounts it
  # inside that guard; either way sparrow_ui's own engine middleware refuses
  # anything that is not local development arriving on a loopback socket, and it
  # runs ahead of every route below the mount.
  mount SparrowUi::Engine => "/sparrowkit" if defined?(SparrowUi::Engine)

  # The host application's own pages. See SmokeController for why the mailbox
  # lives here rather than in the engine.
  root to: "smoke#index"
  get "mailbox", to: "smoke#mailbox"
  post "mailbox/clear", to: "smoke#clear_mailbox", as: :clear_mailbox
  post "rate-limits/clear", to: "smoke#clear_rate_limits", as: :clear_rate_limits
  post "passkey-offer/decline", to: "smoke#decline_passkey", as: :decline_passkey

  # A page behind SparrowAuth::RequiresLiveSession. The engine's own management
  # pages are gone — a buyer generates their own — so the concern needs a host
  # controller to be exercised in, the same way tenancy has widgets below.
  get "account-settings", to: "account_settings#show"

  # A tenant-scoped corner of the host application, for exercising the tenancy
  # helpers over real HTTP rather than against a controller built in a spec.
  get "widgets", to: "widgets#index"
  post "widgets", to: "widgets#create"
  post "widgets/destroy-all", to: "widgets#destroy_all"
  post "widgets/switch", to: "widgets#switch"
  get "widgets/whoami", to: "widgets#whoami"

  # Non-browser endpoints, authenticated by bearer token.
  get "api/taste", to: "api_taste#show"
  get "api/trade", to: "api_trade#show"
  get "api/unnamed", to: "api_unnamed#show"

  # Behind the permission gate. Every one of these is a way of getting
  # authorization wrong; see ProjectsController for what each is for.
  get "projects/public", to: "projects#public_page"
  get "projects/blank-skip", to: "projects#blank_skip"
  get "projects/unnamed", to: "projects#unnamed_requirement"
  get "projects/both", to: "projects#both_requirements"
  get "projects/misspelt-role", to: "projects#misspelt_role"
  get "projects/misspelt-permission", to: "projects#misspelt_permission"
  get "projects/misspelt-role-in-a-view", to: "projects#misspelt_role_in_a_view"
  get "projects/:id", to: "projects#show"
  post "projects/:id/upload", to: "projects#upload"
  delete "projects/:id", to: "projects#destroy"
  get "projects/:id/forgotten", to: "projects#forgotten"
  get "projects/:id/peeked", to: "projects#peeked"

  # The same gate, declared once in the class body.
  get "gated-projects/added-later", to: "gated_projects#added_later"
  get "gated-projects/tightened", to: "gated_projects#tightened"
  get "gated-projects/:id", to: "gated_projects#show"

  # For spec/generators/generated_screens_run_spec.rb, which generates the
  # sign-in screen and drives it with the test helpers a buyer gets. Same
  # reasoning as the ledger route below: declared here rather than drawn inside
  # the spec, because redrawing an application's routes mid-suite runs the
  # reloader and every autoloaded constant another spec file is holding becomes
  # a different class.
  get "sign-in", to: "sign_in#new", as: :sign_in
  post "sign-in", to: "sign_in#create"
  get "sign-in/code", to: "sign_in#edit", as: :sign_in_code
  post "sign-in/code", to: "sign_in#update"

  # For spec/generators/generated_code_runs_spec.rb, which generates a Ledger
  # and drives the generated controller over real HTTP.
  #
  # Declared here rather than drawn inside that spec. Redrawing an application's
  # routes mid-suite runs the reloader, which unloads every autoloaded constant
  # -- so SparrowAuth::Membership becomes a NEW class, and every spec file that
  # captured the old one in `described_class` starts failing an identity check
  # for reasons nothing in its own file explains. A route to a controller that
  # only exists during one example costs nothing until it is asked for.
  resources :ledgers
end
