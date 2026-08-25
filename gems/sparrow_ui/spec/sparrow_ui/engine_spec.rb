# frozen_string_literal: true

require "rails_helper"

RSpec.describe SparrowUi::Engine do
  # Every Ruby file the gem ships. Explicit encoding, because
  # Encoding.default_external follows the locale and a runner without LANG set
  # reads a UTF-8 source file back as US-ASCII.
  def gem_sources
    Dir[File.expand_path("../../{lib,config}/**/*.rb", __dir__)].sort
  end

  # Comments dropped. Several of them discuss mounting at length, precisely
  # because the gem does not do it.
  def code_only(path)
    File.read(path, encoding: "UTF-8").lines.reject { |line| line.strip.start_with?("#") }.join
  end

  it "isolates its namespace, so a host's routes and helpers stay separate" do
    expect(described_class.isolated?).to be(true)
  end

  it "puts its own views on the lookup path" do
    expect(described_class.paths["app/views"].existent)
      .to include(a_string_ending_with("sparrow_ui/app/views"))
  end

  it "adds no view helpers to the host at all" do
    # The gem ships no components. A panel writes Tailwind classes directly, so
    # there is nothing to mix in and nothing of ours in a host's view context.
    expect(ActionView::Base.private_instance_methods.grep(/\Ask_/)).to be_empty
  end

  it "carries the console's routes on its own set, never on the host's" do
    # It shipped none at all until the console existed. What keeps them off the
    # internet now is the gate, not their absence.
    expect(described_class.routes.routes).not_to be_empty
    expect(described_class.routes).not_to be(Rails.application.routes)
  end

  it "does not mount itself -- where it lives is the host's decision" do
    # The dummy mounts it at /sparrowkit; a real host mounts it inside a
    # `Rails.env.development?` guard. An engine that drew its own mount into
    # the application would be a route a customer could reach in production,
    # which is exactly what this gem must never be.
    #
    # `mount` alone is not the offence, and reading it as one made this spec
    # fail the moment the registry landed: config/routes.rb mounts each panel a
    # module registered, INSIDE this engine's own route set and below its gate,
    # which is the console working as designed. What is forbidden is this
    # engine mounting itself, and anything at all reaching for the host's route
    # set.
    offenders = gem_sources.select { |path|
      code_only(path).match?(/^\s*mount\s+SparrowUi|Rails\.application\.routes/)
    }

    expect(offenders).to be_empty,
      "the mount belongs in the host's routes file. Found the gem drawing one in: #{offenders.join(", ")}"
  end

  it "gates everything below it from its own middleware stack, not the host's" do
    # On the engine, so panels other gems mount below /sparrowkit are covered
    # without inheriting anything from us -- and so the guard does not sit in
    # front of the host's own application.
    #
    # `app` first, and it is not decoration. Until the engine's Rack app is
    # built, config.middleware is a MiddlewareStackProxy -- a recording of
    # `use` calls with no readable list. Building collapses it into a real
    # ActionDispatch::MiddlewareStack. It is memoised, so this is free once any
    # request has been served, and this spec has to pass in either order.
    described_class.app

    expect(described_class.middleware.middlewares.map(&:klass))
      .to include(SparrowUi::Console::LoopbackGuard)
  end

  it "points a host with no asset pipeline at the compiled stylesheet" do
    # A mountable engine cannot assume a host has an asset pipeline, or which
    # one, so the console inlines this file rather than linking it. The dummy
    # app's layout does exactly that.
    expect(File).to exist(SparrowUi.stylesheet_path)
  end
end
