# frozen_string_literal: true

module SparrowUi
  module Console
    # The console's front page: what is installed, how it is configured, and
    # what to do with it.
    #
    # No gate here. The engine's middleware refused anything that is not local
    # development before routing ran, and it covers every panel mounted below
    # this one too.
    class HubController < ActionController::Base
      layout "sparrow_ui/console"

      # Asked for rather than inherited.
      #
      # ActionController::Base gets forgery protection from
      # `config.action_controller.default_protect_from_forgery`, which is on
      # from the 5.2 defaults -- so this page has been protected all along by a
      # line in somebody else's config file. An application that loads older
      # defaults, or sets it false for an API, silently turns it off here too;
      # and this controller writes credentials.yml.enc.
      #
      # :exception rather than :null_session. A console form that fails its
      # token should say so, not quietly save half of nothing.
      protect_from_forgery with: :exception

      # What a developer is told to paste into an assistant, above each module's
      # own section. Says what the thing IS, so the rest reads as detail.
      PREAMBLE = <<~TEXT
        I am building a Rails application on SparrowKit, a set of Rails engines
        that provide authentication, transactional and marketing email, and
        subscription billing. The engines are already installed and configured;
        what follows describes how, and what they give me.

        Follow these rules when writing code for this application:
        - Use the engines' models and helpers. Do not reimplement what they
          already do, and do not add a gem that duplicates one of them.
        - Never hardcode an API key or a secret. They live in Rails encrypted
          credentials, under one top-level key per gem, and the engines read
          them at boot.
        - Anything below marked NOT set is not yet configured. Say so rather
          than writing code that assumes it.
      TEXT

      def show
        @panels = SparrowUi::Console.panels

        # Asked once and used twice -- the steps and the prompt are the same
        # facts. Each call runs a module's code, so asking again per section
        # would double that for no gain.
        @guided = @panels.filter_map { |panel|
          guide = panel.guide
          [panel, guide] if guide.any?
        }

        @prompt = build_prompt
        @install_log = install_log
        load_app_url
      end

      # The one fact more than one panel needs.
      #
      # Saved here rather than typed into each panel, because the panels want
      # different SHAPES of the same thing -- a bare host for the domain
      # passkeys bind to, the whole address for where a processor returns a
      # customer -- and asking twice is asking for the two to disagree.
      #
      # Authentication READS this rather than keeping a copy: its panel shows
      # the domain and does not store one unless somebody deliberately overrides
      # it, so changing the address here changes where passkeys bind. That is
      # why this page says what that costs.
      def update
        unless Settings.writable?
          flash[:alert] = "Nothing was saved: #{Settings.not_writable_reason}"
          return redirect_to(root_path)
        end

        url = params[:app_url].to_s.strip

        if url.present? && !valid_app_url?(url)
          flash[:alert] = "#{url.inspect} is not a web address. It needs to start " \
                          "with http:// or https:// and name a host, like " \
                          "https://example.com."
          return redirect_to(root_path)
        end

        # Blank writes nil, which Settings.write treats as "remove this" -- so
        # clearing a box puts the panels back to having no default rather
        # than defaulting them to an empty string.
        Settings.write(
          Settings::CONSOLE_KEY,
          {app_url: url.presence, app_name: params[:app_name].to_s.strip.presence}
        )

        redirect_to root_path, notice: "Saved."
      end

      private

      def load_app_url
        @app_url = Settings.app_url
        @app_name = Settings.app_name
        @writable = Settings.writable?
        @not_writable_reason = @writable ? nil : Settings.not_writable_reason
        @passkey_domain_inherited = passkey_domain_inherited?
      end

      # Whether changing the address here also changes the domain passkeys bind
      # to, which is the one consequence of editing this box that cannot be
      # undone by editing it back.
      #
      # False when sparrow_auth is not installed, and false when it holds a
      # domain of its own — somebody who set a different one there decoupled the
      # two deliberately, and warning them anyway would be false. A warning that
      # is sometimes false is one people learn to click past.
      #
      # Asked with `defined?` rather than by depending on the gem, the same way
      # the roles panel asks about sparrow_pay. This is a development-only
      # console reporting on whatever happens to be installed beside it.
      def passkey_domain_inherited?
        return false unless defined?(::SparrowAuth)

        Settings.read(::SparrowAuth::CREDENTIALS_KEY)[:webauthn_rp_id].blank?
      end

      def valid_app_url?(url)
        uri = URI.parse(url)

        uri.is_a?(URI::HTTP) && uri.host.present?
      rescue URI::InvalidURIError
        false
      end

      # Where the installer put everything it did not print.
      #
      # The install is deliberately quiet -- a heading and a line per module --
      # so the file that holds the detail has to be named somewhere a developer
      # will actually look. It scrolled past in the terminal once, and this page
      # is where they are standing when they wonder what happened.
      #
      # nil when there is no log, which is every application installed before
      # the installer existed, or one set up by hand. A path that is not there
      # is worse than no path.
      def install_log
        path = Rails.root.join("log", "sparrowkit-install.log")

        path.exist? ? path.relative_path_from(Rails.root).to_s : nil
      rescue
        nil
      end

      def build_prompt
        briefs = @guided.filter_map { |_panel, guide| guide.brief }
        return nil if briefs.empty?

        ([PREAMBLE.strip] + briefs).join("\n\n")
      end
    end
  end
end
