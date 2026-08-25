# frozen_string_literal: true

require "rails_helper"

# The console's shared layout, which every page under /sparrowkit renders --
# the hub and every module's panel, including ones no gem has written yet.
#
# Asserted here rather than in each panel's own suite: a panel that had to
# remember to render the footer is a panel that will forget, and a spec in
# sparrow_mail would not notice sparrow_auth dropping it.
RSpec.describe "the console layout", type: :request do
  before { allow(Rails.env).to receive(:development?).and_return(true) }

  def show = get("/sparrowkit", env: {"REMOTE_ADDR" => "127.0.0.1"})

  # The header's nav. Which panel counts as current is Panel#current?, tested
  # exhaustively against every near-miss path in its own spec; what is left to
  # prove here is the wiring -- that the nav renders from the registry, and
  # that the prefix it builds hrefs from is the right one.
  #
  # The dummy boots with sparrow_mail, so :mail is registered AND mounted, and
  # /sparrowkit/mail is a real page. Extra panels are added around an example
  # rather than the registry being reset, because resetting would unregister
  # the only panel with a route.
  describe "the module nav" do
    # A real Rack application, because config/routes.rb mounts every registered
    # panel and `mount` refuses anything that cannot answer a request.
    #
    # This used to pass `Class.new`, which is not mountable. Routes are drawn
    # lazily, so it only broke when something reloaded them while a fake panel
    # was registered -- which showed up as this file failing on roughly one seed
    # in twenty, with an error naming config/routes.rb and nothing pointing
    # here. SparrowUi::Console.register now refuses it at the registration,
    # where the mistake is.
    def mountable = ->(_env) { [200, {"content-type" => "text/plain"}, ["a panel"]] }

    def with_panels(specs)
      specs.each do |key, (name, short_name)|
        SparrowUi::Console.register(
          key: key, name: name, short_name: short_name, engine: mountable
        )
      end
      yield
    ensure
      specs.each_key { |key| SparrowUi::Console.registry.delete(key) }
    end

    # The whole anchor for one panel, markup and all.
    def nav_link_for(key)
      response.body[%r{<a href="/sparrowkit/#{key}".*?</a>}m]
    end

    # ...and roughly what it says, tags stripped and whitespace collapsed.
    #
    # Asserted on the text rather than on `>Auth</a>`, which is what these read
    # before the status glyph was added: the link's last child is now an SVG,
    # so an exact-markup match breaks on a change that alters nothing a reader
    # sees. The label is the promise; the tags around it are not.
    #
    # Roughly, and only good enough for `start_with`. It cannot tell that the
    # glyph's <title> is inside an aria-hidden subtree and so is not part of
    # the accessible name at all -- which is why the announcement ORDER is
    # asserted on the markup below rather than on this.
    def nav_label_for(key)
      nav_link_for(key)&.gsub(/<[^>]*>/, " ")&.gsub(/\s+/, " ")&.strip
    end

    it "links every registered panel by its short name" do
      with_panels(auth: ["Authentication", "Auth"], pay: ["Payments", "Pay"]) do
        show

        expect(nav_label_for(:auth)).to start_with("Auth")
        expect(nav_label_for(:pay)).to start_with("Pay")
      end
    end

    it "falls back to the full name for a module that offered no short one" do
      show

      expect(nav_label_for(:mail)).to start_with("Mail")
    end

    # The prefix is the part that has actually been wrong, and the bug hides on
    # the one page nobody rechecks. `request.script_name` is sparrow_ui's mount
    # on the hub and the PANEL's mount inside a panel, so a nav built from it
    # renders correct links on the front page and /sparrowkit/mail/mail
    # everywhere else. This asserts from inside a panel for that reason.
    it "builds the same absolute links from inside a panel as from the hub" do
      get "/sparrowkit/mail", env: {"REMOTE_ADDR" => "127.0.0.1"}

      expect(response.body).to include(%(<a href="/sparrowkit/mail"))
      expect(response.body).not_to include("/sparrowkit/mail/mail")
    end

    it "marks the panel being viewed, and only that one" do
      with_panels(auth: ["Authentication", "Auth"]) do
        get "/sparrowkit/mail", env: {"REMOTE_ADDR" => "127.0.0.1"}

        expect(response.body).to match(%r{href="/sparrowkit/mail"\s+aria-current="page"}m)
        expect(response.body).not_to match(%r{href="/sparrowkit/auth"\s+aria-current="page"}m)
      end
    end

    # Matched on the anchor rather than on the word. This layout inlines the
    # whole compiled stylesheet, and the `aria-[current=page]:` utilities put
    # the string "aria-current" in the page whatever the nav renders -- so a
    # bare `not_to include` here passes for the wrong reason on a good day and
    # fails for the wrong reason on this one.
    it "marks nothing on the hub" do
      show

      expect(response.body).not_to match(/<a href="[^"]*"\s+aria-current/m)
    end

    # The glyph beside each link. Four states, two shapes: `ready` is the tick,
    # and attention, unconfigured and unknown are all the question mark, because
    # from the header they mean the same thing -- there is something here you
    # have not finished.
    describe "the status glyph" do
      def register_with(key, name, status)
        SparrowUi::Console.register(key: key, name: name, engine: mountable, status: status)
        yield
      ensure
        SparrowUi::Console.registry.delete(key)
      end

      it "shows a tick for a module that is ready" do
        register_with(:auth, "Auth", -> { {state: :ready, detail: "All set."} }) do
          show

          expect(nav_link_for(:auth)).to include("text-emerald-600")
          expect(nav_link_for(:auth)).to include("<title>Ready</title>")
        end
      end

      %i[attention unconfigured].each do |state|
        it "shows a question mark for a module reporting #{state}" do
          register_with(:auth, "Auth", -> { {state: state, detail: "Look here."} }) do
            show

            expect(nav_link_for(:auth)).to include("text-amber-600")
            expect(nav_link_for(:auth)).not_to include("text-emerald-600")
          end
        end
      end

      # A module that failed to answer is not a module that is fine, and no
      # glyph at all would be indistinguishable from a console built before
      # this existed.
      it "shows a question mark for a module whose status raised" do
        register_with(:auth, "Auth", -> { raise IOError }) do
          show

          expect(nav_link_for(:auth)).to include("text-amber-600")
          expect(nav_link_for(:auth)).to include("<title>Unknown</title>")
        end
      end

      # WCAG 1.4.1: colour is never the only signal. The two glyphs are
      # different shapes, and the state is also in words for a screen reader.
      it "spells the state out for anything reading the page aloud" do
        register_with(:auth, "Auth", -> { {state: :ready} }) do
          show

          expect(nav_link_for(:auth)).to match(/<span class="sr-only">: Ready<\/span>/)
        end
      end

      # The words come AFTER the visible name, so the link announces
      # "Auth: Ready" -- which still begins with what is written on it, as WCAG
      # 2.5.3 asks so that "click Auth" keeps working for speech input.
      #
      # Asserted on document order, because document order is what decides
      # announcement order. Putting the partial before the name in the layout
      # would make this link read ": Ready Auth", and nothing else in this file
      # would notice.
      it "reads the name before the state" do
        register_with(:auth, "Auth", -> { {state: :ready} }) do
          show

          expect(nav_link_for(:auth)).to match(/>Auth\s*<svg.*<span class="sr-only">: Ready/m)
        end
      end

      # The glyph is out of the accessibility tree, or the link would announce
      # its state twice -- once from the SVG title, once from the sr-only span.
      it "hides the glyph itself from the accessibility tree" do
        register_with(:auth, "Auth", -> { {state: :ready} }) do
          show

          expect(nav_link_for(:auth)).to include('<svg aria-hidden="true"')
        end
      end
    end
  end

  describe "the theme switcher" do
    it "applies a stored choice in the head, before anything is painted" do
      show

      head = response.body[/<head>.*?<\/head>/m]
      expect(head).to include("sparrowkit-console-theme")
      expect(head).to include("data-theme")
    end

    # Hidden by the utility, not the attribute: `[hidden]` comes from the
    # browser's own stylesheet and any author `display` rule beats it, so
    # `flex` on the same element would win and the control would never be
    # hidden at all.
    it "hides the control until scripting reveals it" do
      show

      expect(response.body).to match(/<div id="sk-theme".*?class="hidden /m)
    end

    it "offers system, light and dark" do
      show

      %w[system light dark].each do |choice|
        expect(response.body).to include(%(data-sk-theme="#{choice}"))
      end
    end

    # Which button is lit is the script's job, since only the script can read
    # what was stored. The server renders all three unlit rather than guessing
    # Dark, so a developer who chose Light never sees Dark lit for a frame.
    it "lights nothing until the script has read the stored choice" do
      show

      expect(response.body).not_to include(%(aria-pressed="true"))
    end

    # The default is dark, and it is dark in the STYLESHEET rather than in
    # JavaScript: `dark:` applies to any element that is not inside an explicit
    # light or system choice. So a page with no data-theme -- a fresh install,
    # or scripting off -- is already dark when the CSS parses, with nothing to
    # correct afterwards and nothing to flash.
    it "renders no data-theme, which is the dark default" do
      show

      expect(response.body).to match(/<html lang="en">/)
    end
  end

  describe "the footer" do
    it "names the product and the company, each linked" do
      show

      expect(response.body).to include(%(<a href="https://sparrowkit.co"))
      expect(response.body).to include(%(<a href="https://sparrowsoft.co"))
      expect(response.body).to match(/SparrowKit<\/a>\s*-\s*a/m)
      expect(response.body).to match(/SparrowSoft<\/a>\s*project/m)
    end

    it "carries the current year, not one frozen when it was written" do
      show

      expect(response.body).to include("&copy; #{Time.now.year}")
    end

    it "sits outside the yielded content, so a panel cannot displace it" do
      show

      expect(response.body).to match(%r{</main>.*<footer}m)
    end
  end
end
