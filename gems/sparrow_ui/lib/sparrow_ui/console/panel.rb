# frozen_string_literal: true

module SparrowUi
  module Console
    # One module's control panel, as the hub knows it.
    #
    # The hub knows a panel by its name, a sentence, and a traffic light. It
    # does not read the module's configuration and never should: what belongs
    # on a module's panel is that module's business, and the traffic light is
    # the module's own answer rather than sparrow_ui's reading of its settings.
    #
    # Constructed with keywords, always. This carried `keyword_init: true` while
    # the gems supported Ruby 3.1, where a keywordless Struct binds the entire
    # hash to `key` and every panel silently becomes nameless. The floor is 3.2
    # now, where Struct takes keyword arguments natively, so the flag went.
    Panel = Struct.new(:key, :name, :short_name, :summary, :engine, :status_source, :docs_url,
      :guide_source, :setup_order) do
      # What the header's nav calls this panel, where there is room for a word
      # and not a phrase. "Authentication" and "Payments" are right on a card
      # that has a sentence under them and wrong in a row of three links.
      #
      # Asked of the module rather than derived from the key. Chopping
      # `key.to_s.capitalize` off :auth happens to give "Auth", and off a
      # future :sms or :sso gives "Sms" and "Sso" -- a rule that is correct for
      # the three panels that exist and silently wrong for the fourth.
      #
      # Falls back to the full name, so a module that says nothing still gets a
      # link rather than a blank one.
      def short_name
        self[:short_name] || name
      end

      # Relative to the engine's mount, NOT an absolute path. A caller building
      # a link has to join it with the mount prefix -- `request.script_name` in
      # a view -- or every link on the hub points at the host's root.
      def path
        "/#{key}"
      end

      # Whether the page being rendered belongs to this panel, for the header
      # nav's `aria-current`.
      #
      # `prefix` is the console's mount, since `path` is relative to it.
      #
      # A panel owns everything under its mount, so a nested page is still that
      # panel -- hence the second test rather than equality alone. The trailing
      # slash on it is the whole point: without it /sparrowkit/mailer marks the
      # Mail link, and /sparrowkit/paypal marks Payments.
      def current?(request_path, prefix = "")
        href = "#{prefix}#{path}"

        request_path == href || request_path.start_with?("#{href}/")
      end

      # Where this module is documented, on the public site.
      #
      # A module may name its own; the fallback is the convention, so a module
      # that says nothing still gets a working link rather than no link. The
      # docs are versioned and deployed separately from the gems, which is the
      # argument for pointing at them rather than restating them here: a page
      # shipped inside a gem is a page that goes stale at the developer's next
      # `bundle update` and cannot be fixed without a release.
      # Trailing slash, and it is not cosmetic. The published pages are
      # `/docs/auth/index.html`, so `/docs/auth` reaches them only by the
      # host's directory-index redirect. Asking for the address the page
      # actually has costs a character and removes a dependency on a behaviour
      # we do not control.
      def docs_url
        self[:docs_url] || "#{DOCS_URL}/#{key}/"
      end

      # Asked fresh on every render, never memoised: the number the hub prints
      # is about configuration the developer is in the middle of editing, and a
      # cached "Not set up" next to a form they just saved is worse than no
      # badge at all.
      #
      # Rescued because this runs arbitrary module code on the front page. A
      # half-configured module is exactly when a status check is most likely to
      # raise, and exactly when the developer most needs the hub to render --
      # a stack trace at /sparrowkit tells them nothing about which of three
      # modules threw it. One card says "Unknown" instead.
      def status
        return Status.unknown("This module does not report a status.") if status_source.nil?

        Status.from(status_source.call)
      rescue => e
        Status.unknown("Checking this module raised #{e.class}.")
      end

      # How to actually use this module, once it is configured.
      #
      # Asked of the module for the same reason `status` is: sparrow_ui does not
      # know what a passkey is, and a paragraph here about how to sign somebody
      # in would be a second copy of the docs, written by the gem least
      # qualified to write it and updated last.
      #
      # Rescued and defaulted for the same reason too. A guide that raised would
      # take down a page whose whole job is telling somebody what to do next.
      def guide
        return Guide.none if guide_source.nil?

        Guide.from(guide_source.call)
      rescue => e
        # Named, like the sibling rescue above. This one returned Guide.none, so
        # a module whose guide raised was indistinguishable from a module that
        # had nothing to say -- and the guide is what a developer pastes into
        # their assistant, so its silence is the kind nobody investigates.
        Guide.raising(e)
      end
    end
  end
end
