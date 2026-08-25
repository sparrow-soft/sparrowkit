# frozen_string_literal: true

require_relative "sparrow_ui/version"
require_relative "sparrow_ui/console"

# Loaded only when Rails is present, so the gem stays requirable from a bare
# Rakefile. Mirrors how sparrow_mail guards its railtie.
require_relative "sparrow_ui/engine" if defined?(::Rails::Engine)

# SparrowKit's developer-facing theme.
#
# This gem is tooling, not a product gem. It dresses the surfaces a developer
# uses while installing SparrowKit -- the console, the demos, the smoke
# harness, the docs -- and is deliberately absent from a production bundle. It
# is not the component library a customer builds their own application on. See
# docs/decisions/0017-sparrow-ui-dresses-the-workshop.md.
#
# There is no Ruby colour code here and no generated palette. The theme is one
# hand-written stylesheet, tailwind/console.css, built by `rake ui:css` into
# app/assets/stylesheets/sparrow_ui/console.css. Every colour in it is one of
# Tailwind's own, referenced by variable. See
# docs/decisions/0021-stock-tailwind-over-a-derived-palette.md.
module SparrowUi
  # The compiled stylesheet, for a host with no asset pipeline to inline.
  def self.stylesheet_path
    File.expand_path("../app/assets/stylesheets/sparrow_ui/console.css", __dir__)
  end

  # The variable font the theme sets everything in.
  def self.font_path
    File.expand_path("../app/assets/fonts/InterVariable.woff2", __dir__)
  end

  # What the compiled stylesheet writes for the font, and what the layout
  # rewrites before inlining it.
  #
  # The stylesheet is built ahead of time by `rake ui:css` and inlined into a
  # <style> tag, so its `url(InterVariable.woff2)` is relative to the PAGE
  # rather than to a stylesheet -- which made every console page request
  # /InterVariable.woff2 from the host's root, get a routing error, and fall
  # back to a system font while filling the log.
  #
  # It cannot be an absolute path in the compiled file either: a host chooses
  # where to mount this engine, and the build has no idea what that is. So the
  # substitution happens at render time, which is the first moment the answer
  # exists.
  FONT_URL_IN_STYLESHEET = "url(InterVariable.woff2)"
end
