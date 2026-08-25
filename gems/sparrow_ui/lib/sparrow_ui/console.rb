# frozen_string_literal: true

require_relative "console/status"
require_relative "console/guide"
require_relative "console/panel"
require_relative "console/settings"

module SparrowUi
  # The contract between this gem and every other SparrowKit module.
  #
  # A module registers from its engine, guarded, so that it costs nothing when
  # this gem is absent -- which is every production boot:
  #
  #   initializer "sparrow_auth.console" do
  #     next unless defined?(::SparrowUi::Console)
  #
  #     ::SparrowUi::Console.register(
  #       key: :auth,
  #       name: "Authentication",
  #       summary: "Ways in, passkeys, sessions",
  #       engine: SparrowAuth::ConsoleEngine,
  #       status: -> { SparrowAuth::Console::Report.new.status }
  #     )
  #   end
  #
  # sparrow_ui mounts whatever registered at /sparrowkit/<key>. It does not
  # know what any module does, and adding a per-module concept here would
  # defeat the point of the split.
  #
  # `status` is the one exception, and it is deliberately shaped so as not to
  # become one: a callable returning a Status, which is three symbols and a
  # sentence. sparrow_ui learns whether a module is ready without learning what
  # ready means for that module.
  module Console
    # A path segment, nothing cleverer. Rejected rather than sanitised: a key
    # that needs sanitising is a mistake, and quietly rewriting it hides one.
    VALID_KEY = /\A[a-z][a-z0-9_]*\z/

    # Where the public documentation lives. Panels link out to it rather than
    # restating it: prose shipped inside a gem cannot be corrected without
    # cutting a release, and a developer reading a stale page has no way to
    # tell.
    DOCS_URL = "https://sparrowkit.co/docs"

    module_function

    # `setup_order` is where a module belongs in the sequence a developer works
    # through, not a preference about billing. Mail comes first because nothing
    # else finishes without it: an application cannot email somebody a sign-in
    # code until mail sends, so a developer who does authentication first gets
    # as far as a form that appears to work and then goes quiet.
    #
    # Lower is earlier. Anything that does not say sorts after everything that
    # does, and ties break on name, so the hub still reads the same however the
    # gems happened to boot.
    def register(key:, name:, engine:, short_name: nil, summary: nil, status: nil, docs_url: nil,
      guide: nil, setup_order: 100)
      unless key.to_s.match?(VALID_KEY)
        raise ArgumentError, "console key #{key.inspect} must match #{VALID_KEY.source}"
      end

      if registry.key?(key.to_sym)
        raise ArgumentError, "console key #{key.inspect} is already registered by another module"
      end

      # Checked here, where the mistake is, rather than in the route set.
      #
      # config/routes.rb mounts every registered panel, and `mount` refuses
      # anything that does not answer to #call with "A rack application must be
      # specified" -- a message naming the routes file, from a stack that does
      # not mention whoever registered the panel. Because routes are drawn
      # lazily, it also only fires if something happens to reload them while the
      # bad panel is registered, so it presented as a spec failing on roughly
      # one seed in twenty with nothing in its own file to explain it.
      unless engine.respond_to?(:call)
        raise ArgumentError,
          "console panel #{key.inspect} was registered with #{engine.inspect}, which cannot be " \
          "mounted. Pass the module's Engine -- something answering to #call."
      end

      registry[key.to_sym] = Panel.new(
        key: key.to_sym,
        name: name,
        short_name: short_name,
        summary: summary,
        engine: engine,
        status_source: status,
        docs_url: docs_url,
        guide_source: guide,
        setup_order: setup_order
      )
    end

    # Setup order first, then name. The order is the sequence a developer works
    # through; the name breaks ties so the hub reads the same however the gems
    # happened to boot.
    def panels
      registry.values.sort_by { |panel| [panel.setup_order, panel.name] }
    end

    def registry
      @registry ||= {}
    end

    # Specs only. A registry that could be cleared at runtime would be a way to
    # make a panel vanish.
    def reset!
      registry.clear
    end
  end
end
