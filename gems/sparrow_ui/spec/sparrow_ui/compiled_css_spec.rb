# frozen_string_literal: true

# The committed console.css must contain the classes the console's pages use.
#
# This is the only safety net the stylesheet has, and it exists because
# Tailwind's response to a class it cannot resolve is SILENCE. Write
# `bg-nonsense` and you get no rule, no warning, and an unstyled element on a
# page that still returns 200.
#
# It catches the two mistakes that actually happen:
#
#   * a typo, or a class Tailwind does not know; and
#   * a stale build -- somebody edits a page and forgets `rake ui:css`.
#
# Re-running Tailwind here would put Node in the critical path of every Ruby
# test run, which is how a suite stops being run at all. Reading the committed
# output costs nothing.
#
# Hoisted above the describe block: standardrb's Lint/ConstantDefinitionInBlock
# rejects a constant defined inside one, and it is not auto-fixable.
GEM_ROOT = File.expand_path("../..", __dir__)
CSS_PATH = File.join(GEM_ROOT, "app/assets/stylesheets/sparrow_ui/console.css")

# Every directory `@source` names in tailwind/console.css, and only those. A
# module's panel lives in its own gem, so its classes have to be scanned here
# too or the panel renders unstyled with nothing to say so.
#
# Each is the gem's `console` directory, NOT its whole app/views. sparrow_auth
# also ships end-user sign-in pages, hand-styled with `sa-*` class names and no
# Tailwind at all; those are not utilities and have no business in this check.
VIEW_ROOTS = [
  # The layout, which every console page renders inside. Its header is the one
  # piece of markup shared by all four gems, so a class of its own that failed
  # to compile would break every page at once.
  File.join(GEM_ROOT, "app/views/layouts/sparrow_ui"),
  File.join(GEM_ROOT, "app/views/sparrow_ui/console"),
  File.expand_path("../sparrow_auth/console/app/views/sparrow_auth/console", GEM_ROOT),
  File.expand_path("../sparrow_mail/console/app/views/sparrow_mail/console", GEM_ROOT),
  File.expand_path("../sparrow_pay/console/app/views/sparrow_pay/console", GEM_ROOT)
].freeze

# Only plain utilities. Anything carrying `/`, `[`, `:` or `.` is escaped in
# Tailwind's output in ways that make naive matching unreliable, so variants
# like `hover:` and `dark:` are out of scope. The simple majority is enough to
# catch both mistakes above.
SIMPLE_CLASS = /\A[a-z][a-z0-9-]*\z/

RSpec.describe "the compiled console stylesheet" do
  # ERB stripped first: `class="<%= whatever %>"` would otherwise contribute
  # the bare word `whatever`, which is a local variable, not a utility.
  def self.classes_in(source)
    source.gsub(/<%.*?%>/m, " ").scan(/class="([^"]*)"/m).flatten
  end

  def self.used_classes
    VIEW_ROOTS
      .flat_map { |root| Dir.glob(File.join(root, "**", "*.erb")) }
      .flat_map { |path| classes_in(File.read(path, encoding: "UTF-8")) }
      .flat_map(&:split).uniq.grep(SIMPLE_CLASS).sort
  end

  it "exists" do
    expect(File).to exist(CSS_PATH), "run `rake ui:css`"
  end

  it "carries the self-hosted font face" do
    css = File.read(CSS_PATH, encoding: "UTF-8")

    expect(css).to include("@font-face")
    expect(css).to include("InterVariable.woff2")
    # Without this the browser pins Inter's optical-size axis to its default,
    # and a large heading renders with letterforms drawn for body copy.
    expect(css).to include("font-optical-sizing")
  end

  it "is stock Tailwind, with no rules of our own" do
    # The moment this fails, someone has hand-written CSS. That is the thing
    # this gem is meant not to have: the markup decides how a panel looks.
    css = File.read(CSS_PATH, encoding: "UTF-8")

    expect(css).not_to include("--color-brand")
    expect(css).not_to include(".sk-")
  end

  # The console is dark unless somebody says otherwise, and that has to be true
  # of the STYLESHEET rather than of a script. A page served before any script
  # runs -- or with scripting off entirely -- must already be dark, or the
  # default is really "light, corrected a moment later", which is a flash on
  # every navigation.
  #
  # Asserted on one representative utility. `dark:` is one custom variant, so
  # every dark utility in the file is compiled from the same definition and one
  # of them proves the shape.
  describe "the dark variant" do
    let(:css) { File.read(CSS_PATH, encoding: "UTF-8") }

    it "applies with no data-theme at all, which is what makes dark the default" do
      # Not gated on a media query and not gated on [data-theme=dark]: it
      # applies to everything that is not inside an explicit other choice.
      expect(css).to include(
        ".dark\\:bg-slate-950:where(:not([data-theme=light],[data-theme=light] *," \
        "[data-theme=system],[data-theme=system] *))"
      )
    end

    it "asks the machine only when somebody chose to follow it" do
      expect(css).to include(
        "@media (prefers-color-scheme:dark){.dark\\:bg-slate-950:where([data-theme=system]"
      )
    end

    # The browser's own furniture -- scrollbars, caret, date pickers, select
    # menus. Left following the system these are the one part of a dark console
    # that would come out pale on a light-set machine.
    it "sets color-scheme for the default and for each choice" do
      expect(css).to match(/:root\{[^}]*color-scheme:dark/)
      expect(css).to include(":root[data-theme=light]{color-scheme:light}")
      expect(css).to include(":root[data-theme=dark]{color-scheme:dark}")
      expect(css).to include(":root[data-theme=system]{color-scheme:light dark}")
    end
  end

  it "contains every plain utility the console's pages use" do
    css = File.read(CSS_PATH, encoding: "UTF-8")
    missing = self.class.used_classes.reject { |name| css.include?(".#{name}") }

    expect(missing).to be_empty, <<~MSG
      These appear in a console page but not in the compiled stylesheet:

        #{missing.join("\n  ")}

      Either the class is not one Tailwind knows, or the build is stale --
      run `rake ui:css` and commit the result.
    MSG
  end
end
