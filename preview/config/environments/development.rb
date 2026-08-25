# frozen_string_literal: true

# The only environment this host has.
#
# sparrow_ui's gate asks `Rails.env.development?` before anything below the
# mount is routed, so any other environment answers 404 for every console page.
# A preview host that could be started in the wrong environment and simply show
# nothing is a preview host that will be, so there is only one.
Rails.application.configure do
  config.eager_load = false
  config.consider_all_requests_local = true
  config.action_controller.perform_caching = false

  # Left ON. The panels post real forms with real tokens, and a preview that
  # accepted posts the shipped console would reject is a preview that hides the
  # bug it exists to find.
  config.action_controller.allow_forgery_protection = true

  # Every failure explains itself on the page rather than in the terminal,
  # because the browser is where you are standing when it happens.
  config.action_dispatch.show_exceptions = :all

  # Editing an ERB in any of the four gems and refreshing has to show it. That
  # is the whole point of this host, and it takes both of these.
  #
  # `enable_reloading`, not `cache_classes`: the old name still exists in Rails
  # 8 and still assigns something, so setting it looks like it worked and the
  # page keeps serving the template it loaded at boot. Nothing warns.
  config.enable_reloading = true

  # Editing an ERB in any of the four gems must show on refresh, and getting
  # there took reading ActionView rather than guessing at settings. Two traps,
  # both of which look like they are helping:
  #
  # `config.action_view.cache_template_loading = false` reads as "do not cache
  # templates" and does something else. It leaves the template cache in place
  # -- which in Rails 8 is keyed and consulted regardless of
  # ActionView::Resolver.caching, so setting that to false changes nothing
  # either -- and instead installs a ViewReloader that watches the view
  # directories and clears the cache when one changes. Neither setting is
  # needed here; the reloader is the whole mechanism.
  #
  # `config.reload_classes_only_on_change = false` is the one that actually
  # broke it, and it is the more inviting of the two: it reads as "reload
  # harder". It makes the reloader run its callbacks without first asking
  # `updated?` -- and ViewReloader builds its file watcher lazily, inside
  # `updated?`. Never asked, the watcher is never built, and `execute` returns
  # on its first line forever. Views then never reload no matter what else is
  # set. Leaving it at its default is the fix.
  #
  # The stylesheet is not involved in any of this: the layout reads console.css
  # from disk on every render, so `rake ui:watch` in another terminal shows up
  # on a refresh with no restart and no cache to clear.

  config.logger = ActiveSupport::Logger.new($stdout)
  config.log_level = :info
  config.active_support.deprecation = :silence
end
