# frozen_string_literal: true

require "rails_helper"

# Three gates: the gem is packaged into development only, every request must
# arrive on a loopback socket, and every request must be addressed to a loopback
# name. This exercises the second and third -- the first cannot be tested from
# inside the gem it excludes.
RSpec.describe "the console gate", type: :request do
  def get_console(path = "/sparrowkit", remote_addr:, headers: {})
    get path, env: {"REMOTE_ADDR" => remote_addr}, headers: headers
  end

  context "in development" do
    before { allow(Rails.env).to receive(:development?).and_return(true) }

    it "serves a request from IPv4 loopback" do
      get_console(remote_addr: "127.0.0.1")

      expect(response).to have_http_status(:ok)
    end

    it "serves a request from IPv6 loopback" do
      get_console(remote_addr: "::1")

      expect(response).to have_http_status(:ok)
    end

    it "serves the IPv4-mapped form a dual-stack listener reports" do
      get_console(remote_addr: "::ffff:127.0.0.1")

      expect(response).to have_http_status(:ok)
    end

    it "refuses a request from anywhere else" do
      get_console(remote_addr: "10.0.0.4")

      expect(response).to have_http_status(:not_found)
    end

    it "answers 404 and not 403, so the response does not confirm the route" do
      get_console(remote_addr: "10.0.0.4")

      expect(response).to have_http_status(:not_found)
      expect(response).not_to have_http_status(:forbidden)
      expect(response.body).to be_blank
    end

    # The socket check alone is not enough, and this is the case it misses.
    #
    # ngrok, cloudflared and every local reverse proxy connect to the
    # application over loopback, so from the socket's side a visitor from the
    # public internet is indistinguishable from the developer's own browser. A
    # developer who tunnels their machine to show somebody their work was
    # publishing a page that writes credentials.yml.enc and sends real mail.
    describe "a request that arrived through a tunnel" do
      it "is refused, however local the socket looks" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "quiet-otter-42.ngrok-free.app"})

        expect(response).to have_http_status(:not_found)
        expect(response.body).to be_blank
      end

      it "is refused for a plain public name too" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "acme.com"})

        expect(response).to have_http_status(:not_found)
      end

      # Rails' own default test host, which is the same shape as a tunnel's.
      # Worth naming: a suite that did not set a host was testing the 404.
      it "is refused for www.example.com" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "www.example.com"})

        expect(response).to have_http_status(:not_found)
      end
    end

    describe "names that mean this machine" do
      it "serves localhost" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "localhost:3000"})

        expect(response).to have_http_status(:ok)
      end

      # Reserved by RFC 6761 and resolves to loopback by definition, which is
      # what makes it safe to accept by name. Applications doing subdomain work
      # in development use exactly this shape.
      it "serves a subdomain of localhost" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "acme.localhost:3000"})

        expect(response).to have_http_status(:ok)
      end

      it "serves a loopback address used as the name" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "127.0.0.1:3000"})

        expect(response).to have_http_status(:ok)
      end

      it "serves the bracketed IPv6 form a browser sends" do
        get_console(remote_addr: "::1", headers: {"HOST" => "[::1]:3000"})

        expect(response).to have_http_status(:ok)
      end
    end

    # Refusing somebody's own lvh.me or dev.acme.test with no way through would
    # be worse than the risk it guards against, so there is a way through.
    describe "a host the developer added" do
      around do |example|
        was = SparrowUi::Console::LoopbackGuard.also_allow
        SparrowUi::Console::LoopbackGuard.also_allow = ["lvh.me"]
        example.run
        SparrowUi::Console::LoopbackGuard.also_allow = was
      end

      it "is served" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "lvh.me:3000"})

        expect(response).to have_http_status(:ok)
      end

      it "does not let anything else in with it" do
        get_console(remote_addr: "127.0.0.1", headers: {"HOST" => "notlvh.me"})

        expect(response).to have_http_status(:not_found)
      end
    end

    it "reads the socket peer, not a header the client controls" do
      # THE test in this plan. remote_ip walks X-Forwarded-For, which anybody
      # can send. If the gate ever reads it, this turns a 404 into a 200 and
      # the console is on the internet.
      get_console(remote_addr: "10.0.0.4", headers: {"HTTP_X_FORWARDED_FOR" => "127.0.0.1"})

      expect(response).to have_http_status(:not_found)
    end

    it "refuses an address it cannot parse rather than guessing" do
      get_console(remote_addr: "not-an-address")

      expect(response).to have_http_status(:not_found)
    end

    it "gates paths below the mount, not only the mount itself" do
      # The reason the gate is middleware. A panel from another gem is mounted
      # under here and inherits nothing from us; it must still be unreachable.
      get_console("/sparrowkit/anything/at/all", remote_addr: "10.0.0.4")

      expect(response).to have_http_status(:not_found)
    end
  end

  context "outside development" do
    it "refuses even from loopback" do
      allow(Rails.env).to receive(:development?).and_return(false)

      get_console(remote_addr: "127.0.0.1")

      expect(response).to have_http_status(:not_found)
    end
  end
end
