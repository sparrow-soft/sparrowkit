# frozen_string_literal: true

require "ipaddr"

module SparrowUi
  module Console
    # The per-request half of the gate. The other half is packaging: the gem
    # belongs to the template's :development group, so on a production box it
    # is not in the bundle at all.
    #
    # Middleware rather than a base controller, deliberately. Inheritance only
    # protects controllers that remember to inherit, and the panels mounted
    # below this point come from gems that know nothing about us. A middleware
    # on the engine covers all of them, including any added later.
    #
    # THREE CONDITIONS, and the third exists because the first two are not
    # enough. A request has to arrive in development, from a loopback socket,
    # AND be addressed to a loopback name.
    class LoopbackGuard
      # Host names that mean "this machine".
      #
      # `localhost` and anything under `.localhost` are reserved by RFC 6761 and
      # resolve to loopback by definition, which is what makes them safe to
      # accept by name rather than by lookup -- and `app.localhost` is a shape
      # real applications use for subdomain work in development.
      LOOPBACK_NAME = /\A(?:.+\.)?localhost\z/i

      # Anything a developer's own setup needs that is not one of those:
      #
      #   SparrowUi::Console::LoopbackGuard.also_allow = %w[lvh.me dev.acme.test]
      #
      # A list of host names, matched exactly and case-insensitively. Ports are
      # ignored; nothing here is decided by a port.
      class << self
        attr_accessor :also_allow
      end
      self.also_allow = []

      def initialize(app)
        @app = app
      end

      def call(env)
        return not_found unless Rails.env.development?
        return not_found unless loopback_socket?(env["REMOTE_ADDR"])
        return not_found unless loopback_name?(env["HTTP_HOST"])

        @app.call(env)
      end

      private

      # 404 rather than 403. A 403 says "this exists and you may not have it",
      # which tells a scanner the console is installed. Blank body, same
      # reason.
      #
      # Built fresh per request rather than held in a frozen constant. The
      # host's middleware wraps the engine's, and some of it writes into the
      # response triple in place -- Rack::TempfileReaper assigns a BodyProxy
      # over element 2 -- so a frozen array raises FrozenError on the way out.
      def not_found
        [404, {"content-type" => "text/plain"}, []]
      end

      # REMOTE_ADDR, NOT ActionDispatch's remote_ip.
      #
      # remote_ip walks X-Forwarded-For, which the client sends and can forge.
      # REMOTE_ADDR is the socket peer: to fake it you must already be on the
      # machine, at which point the gate is moot.
      #
      # Parsed rather than string-compared, so ::1, 127.0.0.1 and 127.0.0.53
      # all pass and nothing else does. `native` first, because the
      # ::ffff:127.0.0.1 form a dual-stack listener reports is an AF_INET6
      # address and IPAddr#loopback? accepts only ::1 for that family -- it
      # answers false for the mapped form until the mapping is unwrapped.
      def loopback_socket?(address)
        IPAddr.new(address.to_s).native.loopback?
      rescue IPAddr::InvalidAddressError, IPAddr::AddressFamilyError
        false
      end

      # And the name the request was addressed to, which is the condition a
      # tunnel cannot satisfy.
      #
      # THE SOCKET CHECK ALONE IS NOT ENOUGH, and this is why. ngrok,
      # cloudflared, a local nginx and every other reverse proxy connect to the
      # application over loopback -- so from the guard's side, a tunnel from the
      # public internet is indistinguishable from the developer's own browser.
      # A developer who tunnels their machine to show somebody their work
      # therefore published a page that writes credentials.yml.enc, reads them
      # back, and sends real mail.
      #
      # What a tunnel cannot do is change the Host it forwards: it arrives as
      # `something.ngrok-free.app`, because that is the name the visitor typed
      # and the name the tunnel's own routing depends on. So the panel answers
      # only to loopback names, and everything else gets the same blank 404 as a
      # scanner.
      #
      # A local proxy that deliberately rewrites Host to localhost still gets
      # through, and that is the right answer: rewriting it is a thing somebody
      # chose to do on their own machine.
      def loopback_name?(host)
        name = name_without_port(host)
        return false if name.empty?
        return true if name.match?(LOOPBACK_NAME)
        return true if self.class.also_allow.any? { |allowed| allowed.to_s.casecmp?(name) }

        loopback_socket?(name)
      end

      # The host, with any port taken off.
      #
      # Bracketed first, because an IPv6 host arrives as `[::1]:3000` and
      # splitting that on ":" yields "[" -- which is not a loopback anything, so
      # a browser addressed at http://[::1]:3000 met a 404 it could not explain.
      # Only IPv6 is bracketed, so everything else has at most one colon and can
      # be split on it.
      def name_without_port(host)
        raw = host.to_s.strip
        return raw[/\A\[([^\]]*)\]/, 1].to_s if raw.start_with?("[")

        raw.split(":").first.to_s
      end
    end
  end
end
