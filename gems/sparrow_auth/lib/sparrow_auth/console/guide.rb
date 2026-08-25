# frozen_string_literal: true

module SparrowAuth
  module Console
    # What to do with sparrow_auth once it is configured: the steps for a
    # person, and a brief for a model.
    #
    # Built from what is actually stored, not from a template. A brief saying
    # "passwords may be enabled" helps nobody; one saying "passwords are off,
    # so do not render a password field" produces code that fits this
    # application. Specificity is the entire value here.
    #
    # NO SECRETS. This text exists to be pasted into somebody else's chat
    # window, which is the worst possible destination for an HMAC key. It says
    # whether a key is set and never what it is.
    class Guide
      def initialize(settings = ::SparrowUi::Console::Settings)
        @settings = settings
      end

      attr_reader :settings

      def stored
        @stored ||= settings.read(SparrowAuth::CREDENTIALS_KEY)
      end

      def to_h
        {steps: steps, brief: brief}
      end

      # How to USE this, not how to install it.
      #
      # Anybody reading this page has already installed -- the console is only
      # reachable through a mounted engine, and the installer mounted it. Steps
      # telling them to copy migrations and add a mount line describe work that
      # is already done, and reading "run bin/rails db:migrate" on the front
      # page of a working application is how somebody concludes it is not
      # working.
      #
      # EVERY METHOD NAMED HERE EXISTS. Two did not: `sparrow_auth_signed_in?`
      # and `current_account.can?(...)` were both invented, appeared on this
      # page and in the prompt meant for pasting into an assistant, and would
      # have produced confidently wrong code. Checked against the source before
      # writing, and worth checking again before adding to.
      def steps
        [
          "# app/controllers/application_controller.rb\ninclude SparrowAuth::Tenancy",
          "# Then, in any controller or view\ncurrent_account       # the signed-in SparrowAuth::Account, or nil\ncurrent_organization  # the tenant this request is for, or nil",
          "# app/models/invoice.rb -- one line makes every query tenant-scoped\ninclude SparrowAuth::Tenanted",
          "# The role somebody holds. What it MEANS is yours to decide\ncurrent_account.role_in(current_organization)  # => \"admin\", or nil",
          "# Your own rule, in ordinary Ruby. There is no permission API here\nhead :forbidden unless current_account.role_in(current_organization) == \"admin\""
        ]
      end

      def brief
        <<~BRIEF.strip
          ## Authentication (sparrow_auth)

          Passkeys (WebAuthn) are the primary sign-in method and are always on.
          Email verification is always on too. Neither has an off switch.

          The pages your users see are in THIS application, not in the engine:
          `bin/rails generate sparrowkit:screens` wrote them and you own them.
          The engine serves only Rodauth's own pages under /auth.

          Configuration in this app right now:
          - Passkey domain (Relying Party ID): #{passkey_domain}
          - Name shown in the passkey prompt: #{passkey_prompt_name}
          - Emailed sign-in: #{emailed_sign_in}
          - An emailed sign-in for an unknown address creates an account: #{on_off(:signup_with_code)}
          - Passwords: #{on_off(:passwords_enabled)}
          - Auth email is sent from: #{value(:mail_from)}
          - One-time code signing key: #{stored[:otp_secret].present? ? "set" : "derived by Rails, which is fine"}

          What you get:
          - The engine is mounted at /auth and serves Rodauth's pages there:
            /auth/login, /auth/create-account, /auth/verify-account and the
            passkey ceremonies. Your own sign-in, invitation, members, passkey,
            session and connection screens are in app/ and are yours to edit.
          - `include SparrowAuth::Tenancy` in ApplicationController. That gives
            you `current_account` and `current_organization` in controllers and
            views, both nil when nobody is signed in.
          - `SparrowAuth::Organization` is the tenant. An account can belong to
            several, and billing hangs off the organization rather than off the
            person.
          - `include SparrowAuth::Tenanted` in one of YOUR models and every
            query on it is scoped to the organization in scope. A query made
            with no organization in scope raises `UnscopedQuery` rather than
            returning every tenant's rows, so the mistake shows up on the first
            request in development instead of the day a second customer signs
            up. To cross tenants on purpose, say so out loud with
            `SparrowAuth.across_all_organizations`.
          - A role is a NAME and nothing else. SparrowKit stores it and never
            interprets it: there is no ladder, no ranking, and no notion of one
            role outranking another. `membership.role` is a string you chose.
          - There is no permission API, and you should not look for one.
            Deciding what a role may do is your application's job, because only
            your application knows what its roles are. Write it as ordinary
            Ruby where the decision belongs.
          - Adding somebody to an organization is
            `organization.memberships.create!(account:, role:)`, or
            `Organization.create_with_owner!` for the first member.
          - Inviting somebody who has no account yet goes through
            `SparrowAuth::Invitation`. It refuses until you set
            `config.authorize_invitation` -- a callable given the inviter, the
            organization and the role, returning true to allow. That default is
            deliberate: an invitation grants whatever role it names, so without
            a policy anybody who can reach the method could invite their own
            address as any role, accept it, and be seated.
          - Rescue `SparrowAuth::AccessError` and never `SparrowAuth::Error`.
            The first is every refusal; the second also covers a missing check,
            a misspelt permission and a role written around the guard, and
            turning those into a friendly 403 is the failure this arrangement
            exists to make loud.

          Settings live in Rails encrypted credentials under `sparrow_auth:`.
          Read them with `bin/rails credentials:edit`. Do not hardcode them.

          When writing code for this app: do not build a users table, a sessions
          controller, or a password reset flow. They exist. Build the pages that
          are specific to this product and call the helpers above.
        BRIEF
      end

      private

      def value(name)
        stored[name].presence || "not set"
      end

      # The product name actually shown, on the same terms as the domain below.
      def passkey_prompt_name
        override = stored[:webauthn_rp_name].presence
        return "#{override} (set here, overriding the product name)" if override

        inherited = SparrowAuth.application_name.presence
        return "#{inherited} (the product name)" if inherited

        "not set -- people see the domain instead"
      end

      # The domain passkeys actually bind to, which is inherited from the
      # application's address unless this gem's settings override it. Reading
      # only the override reports a configured application as unconfigured, in
      # a prompt written to be believed.
      def passkey_domain
        override = stored[:webauthn_rp_id].presence
        return "#{override} (set here, overriding the application's address)" if override

        inherited = SparrowAuth.application_host.presence
        return "#{inherited} (from the application's address)" if inherited

        "not set -- set the application's address on the SparrowKit home page"
      end

      # Presence IS the value for `passwords_enabled` -- the name matches the
      # secret mask, so it is stored by being there. See the panel controller.
      def on_off(name)
        (stored.key?(name) && !!stored[name]) ? "on" : "off"
      end

      # A code somebody types, or a link they open -- one or the other, never
      # both. Said in words rather than as the stored symbol, because this
      # paragraph is read by somebody deciding what to write next.
      def emailed_sign_in
        if SparrowAuth.config.emailed_sign_in_link?
          "a LINK, which only works in the browser that asked for it. " \
            "An address with no account cannot become one this way -- new people " \
            "arrive by invitation or through /auth/create-account"
        else
          "a six-digit CODE, typed on the page that asked for it"
        end
      end
    end
  end
end
