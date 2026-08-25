# frozen_string_literal: true

module SparrowAuth
  module Console
    # The one page sparrow_auth contributes to the developer console: the domain
    # passkeys bind to, where auth mail comes from, which ways in are open, and
    # the two HMAC keys.
    #
    # It configures a deliberately small part of SparrowAuth::Configuration.
    # Everything a host sets once in config/initializers/sparrow_auth.rb and
    # never opens again -- the provisioning callbacks, which organization a
    # request is for, the expiries, path_prefix -- stays there, and the
    # page says so rather than growing a box for it. A setting that appears in
    # two places is a setting that will disagree with itself.
    #
    # Nothing here touches roles or permissions. Those are the application's
    # policy, expressed in the roles the host declares, and a console that
    # offered to configure them would be re-inventing the role model this
    # deliberately does not have: who may do what is decided in the host's own
    # code, where it can be read and tested, rather than in a settings page.
    #
    # No gate here. sparrow_ui's engine middleware refused anything that was not
    # local development before routing ran, and it covers every panel mounted
    # below it, including this one.
    class SparrowkitController < ActionController::Base
      # This engine's URL helpers, included by hand, and the line is load-bearing.
      #
      # Rails gives an isolated engine's controllers their route helpers through
      # the FIRST module in the class's ancestry that answers
      # `railtie_routes_url_helpers` -- see AbstractController::Railties::RoutesHelpers.
      # That module is SparrowAuth, and SparrowAuth::Engine claimed it first, so
      # without this every controller under this namespace resolves its paths
      # against the auth engine's route set and `sparrowkit_path` does not exist
      # there. The failure is at render time, on a page that otherwise looks
      # fine, which is a poor place to discover it.
      include SparrowAuth::ConsoleEngine.routes.url_helpers

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

      MODULE_KEY = SparrowAuth::CREDENTIALS_KEY

      # What a checkbox sends. Rendered as a hidden field plus a box, so the
      # parameter is always present and always one of these two -- a checkbox
      # alone sends nothing when it is off, and "absent" and "off" would then be
      # the same request as "the client never rendered the control".
      ON = "1"
      OFF = "0"
      SWITCHES = [:signup_with_code, :passwords_enabled].freeze

      # Everything else on the page: one line of text each.
      #
      # `sender_name` and `sender_email` are two boxes over one stored value --
      # they are joined into `mail_from`, which is what
      # SparrowAuth::Configuration takes, and never stored apart.
      TEXT = [
        :webauthn_rp_id, :webauthn_rp_name, :sender_name, :sender_email,
        :otp_secret
      ].freeze

      # The two shapes emailed sign-in comes in, as a radio rather than two
      # boxes. See SparrowAuth::Configuration#emailed_sign_in for why neither
      # "both" nor "neither" is a state this can reach.
      MECHANISMS = SparrowAuth::Configuration::EMAILED_SIGN_IN

      # The providers this panel offers, and the gem each one needs.
      #
      # A short list rather than everything OmniAuth can do, because every entry
      # is a promise: the panel says the gem is missing, names the line to add,
      # and then has to be right about what that line is. Anything else is
      # configured in config/initializers/sparrow_auth.rb, where a developer can
      # pass whatever options their strategy takes.
      SOCIAL = [
        {key: :google_oauth2, name: "Google", gem: "omniauth-google-oauth2"},
        {key: :apple, name: "Apple", gem: "omniauth-apple"}
      ].freeze

      # A domain, which is all a WebAuthn RP ID may be: no scheme, no port, no
      # path, no trailing dot. Checked rather than cleaned up, because
      # "https://example.com" pasted from a browser bar and quietly rewritten is
      # exactly the kind of help that later reads as a bug.
      #
      # A single label is allowed, because `localhost` is one and is a perfectly
      # good RP ID -- WebAuthn treats it as a secure origin, which is what makes
      # passkeys work on a development machine at all. So this refuses what
      # cannot be a domain rather than insisting on what usually is one.
      RP_ID = /\A[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/i

      # How many accounts the picker offers.
      #
      # Enough to sign in as a viewer, then an admin, then somebody in another
      # organization, which is what the harness is for. Not a paginated list of
      # everybody: this is a development machine, and a page that needs paging
      # is a page that has stopped being a harness.
      HARNESS_LIMIT = 25

      def show
        load_panel
        render :show
      end

      # Signs the developer in as somebody, through the flow their own users go
      # through.
      #
      # THERE IS NO BYPASS HERE, and that is the design rather than an accident
      # of it. This asks SparrowAuth::SignIn for a code exactly as the generated
      # sign-in screen does, reads it back out of the mailbox the way a person
      # reads their email, and redeems it. Everything that follows from that is
      # a property worth having:
      #
      #   * only a verified account can be signed in, because that is what the
      #     flow enforces and there is no second path that does not;
      #   * the one-code-per-address-per-minute limit applies, and is reported
      #     rather than worked around;
      #   * a real auth_events row and a real, revocable session come out of it,
      #     so the sessions screen shows this exactly as it shows a person.
      #
      # A method that wrote the session directly would be shorter, would work,
      # and would be the one code path in the product that proves nothing. It
      # would also be a sign-in-as-anybody primitive sitting in a shipped gem,
      # one `Rails.env` check away from being reachable.
      def sign_in_as
        account = SparrowAuth::Account.find_by(id: params[:account_id])
        return redirect_to(root_path, alert: "No such account.") if account.nil?

        before = SparrowMail.readable_deliveries.size
        request_id = SparrowAuth::SignIn.request(
          email: account.email, ip: request.remote_ip, base_url: request.base_url
        )
        delivered = harness_delivery_for(account.email, sent_before: before)

        if delivered.nil?
          return redirect_to root_path, alert: harness_nothing_sent_message(account)
        end

        # A link is not signed in from here, and that is not a shortcoming.
        #
        # Rodauth stores the key in the session of the browser that OPENS the
        # link, which is what stops a mail scanner from spending it. A panel
        # that fetched the link server-side would either fail on that rule or go
        # round it, and going round it is the one thing this harness does not
        # do. So the developer gets the link to click, in the browser they are
        # already sitting in, which is the real flow.
        if SparrowAuth.config.emailed_sign_in_link?
          link = delivered[%r{https?://\S+}]
          return redirect_to root_path, alert: harness_no_link_message if link.nil?

          flash[:sparrow_auth_harness_link] = link
          return redirect_to root_path,
            notice: "A sign-in link for #{account.email} is ready. Open it to finish."
        end

        code = delivered[/\b(\d{6})\b/, 1]
        return redirect_to root_path, alert: harness_no_link_message if code.nil?

        signed_in = SparrowAuth::SignIn.redeem(code: code, request_id: request_id, ip: request.remote_ip)
        start_session(signed_in)

        redirect_to root_path, notice: "Signed in as #{signed_in.email}. Your application now sees you as them."
      rescue SparrowAuth::AccessError => e
        redirect_to root_path, alert: "That did not sign anybody in: #{e.message}"
      end

      def update
        unless settings.writable?
          return refuse("Nothing was saved: #{settings.not_writable_reason}")
        end

        SWITCHES.each do |name|
          value = params[name].to_s
          next if value == ON || value == OFF

          return refuse("#{name} arrived as #{params[name].inspect}, which is neither on nor off. " \
                        "Nothing was saved.")
        end

        if mechanism.nil?
          return refuse("An emailed sign-in is #{MECHANISMS.join(" or ")}, and " \
                        "#{params[:emailed_sign_in].inspect} is neither. Nothing was saved.")
        end

        # A hand-made request can send a hash where the page sends a line of
        # text. Refused rather than coerced: `scalar` below reads anything else
        # as blank, and blank is a deliberate clear, so coercing here would let
        # a malformed request quietly wipe a setting.
        TEXT.each do |name|
          value = params[name]
          next if value.nil? || value.is_a?(String)

          return refuse("#{name} arrived as #{value.class}, which is not a line of text. " \
                        "Nothing was saved.")
        end

        if overriding_rp_name? && scalar(:webauthn_rp_name).empty?
          return refuse("A different name in the passkey prompt needs a name in the box. Turn " \
                        "that switch off to use the product name from the SparrowKit home page.")
        end

        if overriding_rp_id?
          rp_id = scalar(:webauthn_rp_id)

          if rp_id.empty?
            return refuse("A different passkey domain needs a domain in the box. Turn that switch " \
                          "off to use the address from the SparrowKit home page instead.")
          end

          unless rp_id.match?(RP_ID)
            return refuse("#{rp_id.inspect} is not a domain. A WebAuthn Relying Party ID is a bare " \
                          "registrable domain — example.com — with no scheme, port or path.")
          end
        end

        email = scalar(:sender_email)
        if !email.empty? && !email.include?("@")
          return refuse("#{email.inspect} is not an email address. Auth mail needs one to be sent from.")
        end

        if email.empty? && !scalar(:sender_name).empty?
          return refuse("A sender name with no address is not somewhere mail can come from. " \
                        "Add the address, or clear the name to fall back to the Mail panel's default sender.")
        end

        alert = rp_id_alert(rp_id)
        settings.write(MODULE_KEY, attributes)

        redirect_to root_path,
          notice: "Authentication settings saved to your Rails credentials.",
          alert: alert
      end

      private

      def settings
        ::SparrowUi::Console::Settings
      end

      # Masked: presence and last four characters for anything whose name reads
      # like a secret, at every depth. Nothing else in this controller reads
      # credentials, so there is no path by which a stored secret reaches a view.
      def stored_tree
        @stored_tree ||= settings.for_display(MODULE_KEY)
      end

      # The engine's own defaults, for a switch nothing has been stored for yet.
      #
      # A fresh Configuration rather than SparrowAuth.config, deliberately. This
      # page reads and writes ONE store, the credentials tree, and prefilling it
      # from the live configuration would put a value from the host's
      # initializer into a box whose save writes it somewhere else -- two
      # answers to one question, and a save that appears to change nothing.
      def defaults
        @defaults ||= SparrowAuth::Configuration.new
      end

      # The code from the message THIS request produced, out of whichever store
      # mail is landing in.
      #
      # `sent_before` is the whole of it. Reading the most recent code for the
      # address instead looks equivalent and is not: when the once-a-minute
      # limit refuses to issue one, the newest message for that address is the
      # PREVIOUS code, already redeemed and already consumed. The harness then
      # found it, redeemed it, failed, and reported "that code is not valid" --
      # blaming the code for a rate limit, which is the least useful sentence
      # available. If nothing new arrived, nothing was sent.
      #
      # Nil also when a real provider is configured, because then the code went
      # to a real mailbox and there is nothing here to read. Both are reported
      # rather than papered over -- see harness_no_code_message.
      def harness_delivery_for(email, sent_before:)
        arrived = SparrowMail.readable_deliveries(limit: 5)
        return nil if arrived.size <= sent_before

        arrived.find { |message| message.to.any? { |address| address.casecmp?(email) } }&.text
      end

      # The message arrived and did not contain what this application says it
      # sends. Rare, and worth saying rather than failing quietly: it is what a
      # buyer sees if they have edited the mail template past recognition.
      def harness_no_link_message
        if SparrowAuth.config.emailed_sign_in_link?
          "A message was sent, but there is no link in it. Check your copy of the sign-in mail template."
        else
          "A message was sent, but there is no six-digit code in it. Check your copy of the sign-in mail template."
        end
      end

      # Three reasons no code came back, and they need three different actions.
      def harness_nothing_sent_message(account)
        if SparrowMail.configuration.adapter.nil?
          "No mail provider is configured at all, so nothing was sent. " \
            "Nothing to fix here — open the Mail panel."
        elsif mail_readable_from_here?
          "Nothing was sent. One message a minute for one address is the limit, " \
            "so this is usually a second attempt too soon after the first. Wait a moment " \
            "and try again."
        else
          "The message went to #{account.email} through your mail provider, so it is not " \
            "readable from here. Open that mailbox, or clear the provider to have mail " \
            "written to a folder instead."
        end
      end

      # Whether mail this application sends can be read back on this machine.
      #
      # Asked as "is the adapter something that sends to somebody" rather than
      # "is it the preview adapter". Two adapters record instead of sending --
      # preview writes files, test keeps envelopes -- and both are readable;
      # naming one of them here would have made this message wrong under the
      # other, which is exactly how it was wrong first time round.
      def mail_readable_from_here?
        name = SparrowMail.configuration.adapter
        return false if name.nil?

        !SparrowMail.registry.fetch(name).provider?
      rescue SparrowMail::ConfigurationError
        # An adapter whose gem is missing cannot be asked. It is certainly not
        # recording anything here.
        false
      end

      # Rodauth's own session handling, not a hand-rolled one. It is what puts a
      # row in the active-sessions table, which is what makes this session
      # revocable and visible on the sessions screen exactly like anybody
      # else's.
      def start_session(account)
        rodauth.account_from_login(account.email)
        rodauth.send(:login_session, "otp")
      end

      # Whether the developer has generated the screens their customers use.
      #
      # SparrowKit serves no sign-in page, so an application that has not run
      # the generator has nowhere for anybody to sign in -- and the symptom is a
      # 404 at a path nobody wrote, which reads like a bug in the engine.
      # Asked of the route set rather than by recognising the path.
      #
      # `recognize_path` raises ActionController::RoutingError for two different
      # situations -- nothing drawn there, and something drawn there whose
      # controller is missing -- and the second is not "you have not generated
      # the screens". This asks the only question worth asking: is anything
      # drawn at that path at all.
      def screens_generated?
        target = SparrowAuth.config.sign_in_path

        Rails.application.routes.routes.any? do |route|
          route.path.spec.to_s.chomp("(.:format)") == target
        end
      end

      # What the radio sent, or nil for anything it did not.
      #
      # Nil is refused in `update` rather than falling back to the default: the
      # only ways to get here with an unrecognised value are a hand-edited form
      # and a bug, and silently signing everybody in a different way is not the
      # right answer to either.
      def mechanism
        value = params[:emailed_sign_in].to_s.strip.downcase.to_sym

        value if MECHANISMS.include?(value)
      end

      # Provider credentials, in the shape SparrowAuth::Configuration takes.
      #
      # Named keys rather than a positional pair, and that is a masking
      # decision rather than a stylistic one: sparrow_ui masks by the NAME of a
      # key, so `client_secret` is masked wherever it appears and the second
      # element of an array is not masked anywhere.
      #
      # A provider with neither box filled in is left out entirely, so it is
      # absent rather than present-and-empty.
      def social_providers
        SOCIAL.each_with_object({}) do |provider, stored|
          id = params.dig(:social, provider[:key], :client_id).to_s.strip
          secret = params.dig(:social, provider[:key], :client_secret).to_s.strip
          next if id.empty? && secret.empty?

          stored[provider[:key]] = {client_id: id, client_secret: secret}
        end
      end

      # Whether the gem behind a provider is actually in the application's
      # bundle. Asked of Bundler rather than guessed, so the panel can say what
      # is missing instead of offering a control that produces a callback route
      # raising on its first visitor.
      def social_gem_present?(name)
        Gem.loaded_specs.key?(name)
      end

      def load_panel
        @accounts = SparrowAuth::Account.verified.order(:email).limit(HARNESS_LIMIT)
        @signed_in_as = rodauth.rails_account
        @screens_generated = screens_generated?
        @writable = settings.writable?
        @not_writable_reason = @writable ? nil : settings.not_writable_reason

        # What the form should come back showing: whatever was just submitted
        # when a save was refused, and the stored configuration otherwise.
        # Falls back to the host of the address recorded on the hub, so this box
        # arrives filled in for anybody who typed it there. Only when nothing is
        # stored here: a value saved on this page is the developer's answer and
        # is never overwritten by the hub's.
        #
        # The HOST, not the address. A passkey binds to a bare domain -- no
        # scheme, no port, no path -- and handing it "https://example.com:3000"
        # would bind every passkey to a Relying Party ID that never matches.
        # Inherited unless this panel holds a value of its own. A stored value IS
        # the override — there is no separate flag, because a flag and a value
        # can disagree and then something has to decide which lied.
        @inherited_rp_id = settings.app_host.to_s
        @overriding_rp_id =
          if params.key?(:webauthn_rp_id_override)
            params[:webauthn_rp_id_override].to_s == ON
          else
            stored_tree[:webauthn_rp_id].present?
          end
        @rp_id = typed(:webauthn_rp_id) ||
          stored_tree[:webauthn_rp_id].presence ||
          @inherited_rp_id
        # What passkeys will actually bind to once this is saved.
        @effective_rp_id = @overriding_rp_id ? @rp_id : @inherited_rp_id
        # The product's name, on the same terms as the domain above: inherited
        # from the front page unless this panel holds one of its own.
        @inherited_rp_name = settings.app_name.to_s
        @overriding_rp_name =
          if params.key?(:webauthn_rp_name_override)
            params[:webauthn_rp_name_override].to_s == ON
          else
            stored_tree[:webauthn_rp_name].present?
          end
        @rp_name = typed(:webauthn_rp_name) ||
          stored_tree[:webauthn_rp_name].presence ||
          @inherited_rp_name
        @effective_rp_name = @overriding_rp_name ? @rp_name : @inherited_rp_name
        @stored_tree_rp_name = stored_tree[:webauthn_rp_name].to_s
        # Two boxes over one stored value, the same way the Mail panel does it.
        # `mail_from` stays a single RFC 5322 mailbox because that is what
        # SparrowAuth::Configuration takes; the split is for typing, not for
        # storage, so there is nothing to hold in step.
        stored_name, stored_email = settings.split_mailbox(stored_tree[:mail_from].to_s)
        @stored_sender_name = stored_name.to_s
        @stored_sender_email = stored_email.to_s
        @sender_name = typed(:sender_name) || stored_name.to_s
        @sender_email = typed(:sender_email) || stored_email.to_s

        @signup_with_code = switch(:signup_with_code, defaults.signup_with_code)
        @passwords_enabled = switch(:passwords_enabled, defaults.passwords_enabled)

        @otp_secret = stored_tree[:otp_secret]

        # What is STORED, not what is live. Credentials become configuration in
        # an engine initializer, which runs at boot -- so between a save and a
        # restart the two disagree, and the page a developer is looking at
        # should show what they just saved rather than what the running process
        # still believes. Every other control on this page reads the same way.
        @mechanism = mechanism ||
          MECHANISMS.find { |name| name.to_s == stored_tree[:emailed_sign_in].to_s } ||
          defaults.emailed_sign_in
        @mechanisms = MECHANISMS

        # rodauth-omniauth carries the whole feature; without it no provider
        # works however many keys are typed in.
        @omniauth_present = SparrowAuth.config.social?
        @social = SOCIAL.map do |provider|
          stored = stored_tree.dig(:social_providers, provider[:key]) || {}

          provider.merge(
            client_id: params.dig(:social, provider[:key], :client_id) || stored[:client_id].to_s,
            secret_set: stored[:client_secret].is_a?(Hash) && stored[:client_secret][:set],
            gem_present: social_gem_present?(provider[:gem])
          )
        end

        # The RP ID that is already stored, so the page can say what changing it
        # costs. Not a secret and never was: it is a public domain name, sent to
        # the browser in every ceremony.
        @stored_rp_id = stored_tree[:webauthn_rp_id].to_s
        @rp_id_changing = rp_id_changing?(@effective_rp_id)
      end

      # Re-render rather than redirect, so the developer keeps what they typed.
      # flash.now, so it does not survive into the next page.
      def refuse(message)
        flash.now[:alert] = message
        load_panel
        render :show, status: 422
      end

      def attributes
        {
          # nil when it is not being overridden, which is how Settings.write
          # deletes. Storing the inherited value instead would freeze a copy:
          # the front page's address would change and this would not follow it,
          # which for a passkey domain means every enrolled passkey quietly
          # bound to somewhere the application no longer is.
          webauthn_rp_id: (scalar(:webauthn_rp_id) if overriding_rp_id?),
          # nil unless overridden, for the same reason as the domain: a copy
          # taken once stops following the name it was copied from.
          webauthn_rp_name: (scalar(:webauthn_rp_name) if overriding_rp_name?),
          mail_from: settings.compose_mailbox(scalar(:sender_name), scalar(:sender_email)),
          signup_with_code: params[:signup_with_code].to_s == ON,

          # PRESENCE IS THE VALUE, and it has to be, which is worth knowing
          # before changing it. SparrowUi::Console::Settings masks by NAME --
          # anything matching /key|secret|token|password|credential/i -- so a
          # key called `passwords_enabled` comes back from `for_display` as
          # {secret: true, set: true} and never as its value. That rule is
          # right, and weakening it so this one boolean could be read back would
          # trade a secret-on-screen failure for a tidier panel.
          #
          # So the key exists when passwords are on and is REMOVED when they are
          # not: `nil` is how Settings.write deletes, and presence is a question
          # the mask still answers.
          passwords_enabled: (params[:passwords_enabled].to_s == ON) || nil,

          # Blank is passed through to Settings.write, which drops blank SECRETS
          # rather than writing them: the form cannot show a stored key, so it
          # has to submit an empty box, and reading that as "erase it" would
          # wipe the HMAC key on every save. Rotating one is typing a new one.
          otp_secret: scalar(:otp_secret),

          # A code or a link. Refused rather than defaulted if it is neither:
          # quietly choosing one would be this panel deciding how an
          # application signs people in.
          emailed_sign_in: mechanism,

          # nil when nothing was typed for a provider, which is how
          # Settings.write deletes -- so clearing both boxes turns that
          # provider off rather than leaving an empty pair behind for
          # `social?` to count as configured.
          social_providers: social_providers.presence
        }
      end

      # Said on the way out as well as on the page, because a save redirects and
      # a developer who does not reopen this panel would otherwise meet this as
      # a support queue full of people who cannot sign in.
      def rp_id_alert(rp_id)
        return nil unless rp_id_changing?(rp_id)

        "Passkeys already enrolled against #{stored_tree[:webauthn_rp_id]} will not work against " \
          "#{rp_id}. A credential is bound to the Relying Party ID it was created under and cannot " \
          "be moved to another, so everybody who has one has to enrol again."
      end

      # Whether the box is in play at all. Off means this panel stores nothing
      # and the domain comes from the address on the front page.
      def overriding_rp_id?
        params[:webauthn_rp_id_override].to_s == ON
      end

      def overriding_rp_name?
        params[:webauthn_rp_name_override].to_s == ON
      end

      def rp_id_changing?(candidate)
        stored = stored_tree[:webauthn_rp_id].to_s
        return false if stored.empty?

        candidate.to_s != stored
      end

      # A switch's position: what was submitted when a save was refused, then
      # whether the key is stored, then the engine's own default.
      #
      # `passwords_enabled` arrives here masked, as {secret: true, set: true},
      # because of the name. Both shapes are read the same way -- is there a
      # value, and is it a true one -- so the caller does not have to know which
      # of its switches the mask happens to catch.
      def switch(name, fallback)
        submitted = params[name].to_s
        return submitted == ON unless submitted.empty?

        stored = stored_tree[name]
        return fallback if stored.nil?
        return stored[:set] if stored.is_a?(Hash)

        !!stored
      end

      # What was typed, or nil if this request did not carry the field at all.
      # Distinct from "typed nothing", which is a deliberate clear and must
      # survive a refused save.
      def typed(name)
        params.key?(name) ? scalar(name) : nil
      end

      # Form parameters arrive in whatever shape the request felt like. A
      # hand-made request that sends a hash where the page sends a string gets
      # an empty value and the 422 the checks above are for, rather than
      # `#<ActionController::Parameters ...>` written into the credentials file.
      def scalar(name)
        value = params[name]
        value.is_a?(String) ? value.strip : ""
      end
    end
  end
end
