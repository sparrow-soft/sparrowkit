# frozen_string_literal: true

require "bcrypt"
require "securerandom"
require "sequel/core"

module SparrowAuth
  # The single Rodauth configuration this engine ships.
  #
  # Rodauth owns the crypto, the token generation and comparison, the ceremony
  # handling and the flow security. Nothing in here reimplements any of that;
  # it selects features and states the policy this engine will not bend on.
  #
  # Phase 1 enables passwords because it is the only sign-in method that
  # exists yet, and something has to prove signup, verification and signin
  # end to end. Email OTP arrives in Phase 2 and passkeys in Phase 5, at which
  # point passwords become a per-application flag that defaults to off.
  class RodauthMain < Rodauth::Rails::Auth
    # One sentence for every way a sign-in can fail. It names both fields
    # because it must be equally true whichever one was wrong, and it never
    # confirms that the address is one we know.
    LOGIN_FAILURE_MESSAGE = "no account matches that email address and password"

    # Rodauth reports the three ways a sign-in can fail in three ways a client
    # can tell apart. All three are routed through one answer instead.
    UNIFORM_LOGIN_FAILURES = %i[no_matching_login unverified_account invalid_password].freeze

    # The conditional an enumeration probe would read, said as a sentence that
    # is true no matter which branch actually ran.
    RESEND_NOTICE = "If that address has an account awaiting confirmation, another email is on its way."

    # A hash for the sign-in path to compare against when there is no account,
    # so that path costs what the other one costs. See after_no_matching_login.
    #
    # Built lazily from random bytes nobody holds — the point is the work of
    # comparing, never the value.
    #
    # The cost is taken from Rodauth rather than from BCrypt's default, and that
    # is the whole reason this takes an argument. bcrypt bakes its cost into
    # each hash and every increment doubles the work, so a decoy fixed at one
    # cost stops matching the moment an application raises `password_hash_cost`
    # — and it fails in the worst possible direction: raising the cost to be
    # safer would reopen the timing gap this exists to close, wider than it was
    # before. Reading the setting means the two move together.
    #
    # Memoised per cost, because Rodauth uses bcrypt's minimum under
    # RACK_ENV=test and its default elsewhere, so one process can legitimately
    # want more than one.
    def self.decoy_password_hash(cost)
      @decoy_password_hashes ||= {}
      @decoy_password_hashes[cost] ||=
        BCrypt::Password.create(SecureRandom.hex(32), cost: cost).to_s
    end

    configure do
      # webauthn_login is what makes a passkey a way *in* rather than a second
      # factor. Rodauth's webauthn feature alone is two-factor: it can only be
      # presented by somebody who has already signed in another way, which is
      # the opposite of the first one.
      enable :create_account, :verify_account, :login, :logout, :active_sessions,
        :webauthn, :webauthn_login, :webauthn_autofill

      # Sign-in links, which are one of the two shapes emailed sign-in comes in.
      # The other, a six-digit code, is not a Rodauth feature at all -- see
      # SparrowAuth::SignIn.
      #
      # What Rodauth owns is REDEEMING a link, and that half is worth having
      # rather than writing. Its route is GET, then session, then POST: opening
      # the link stores the key in the session and redirects to a bare path, the
      # bare path renders a confirmation form, and the key is spent only on the
      # POST. A mail scanner that prefetches the link therefore gets a cookie
      # and a redirect. It does not sign anybody in, and it does not burn the
      # link before its owner arrives.
      #
      # What Rodauth does NOT own here is ASKING for one. Its
      # email_auth_request route answers an address it does not recognise with a
      # different flash from one it does, which would undo the enumeration work
      # below for exactly one of the two mechanisms. Both requests go through
      # SparrowAuth::SignIn instead, which answers all four situations the same
      # way and puts both mechanisms under one rate limit.
      #
      # ENABLED WHETHER OR NOT THIS APPLICATION SENDS LINKS, and that is not
      # laziness. Rodauth reads its feature list once, when this class is
      # configured; SparrowAuth::SignIn reads the setting on every call. A
      # version of this that asked `if SparrowAuth.config.emailed_sign_in_link?`
      # tied the two together at the one moment they can disagree -- so an
      # application that set the mechanism anywhere but before this class was
      # configured got a setting that changed nothing at all, silently, which is
      # precisely the class of defect this release exists to remove.
      #
      # The route existing costs nothing. It can only sign in somebody holding a
      # key this application issued, and keys are only ever issued by SignIn.
      #
      # internal_request comes with it because SignIn asks for a link from
      # outside any Rodauth route -- it is called by the application's own
      # sign-in screen, which is a plain Rails controller.
      enable :email_auth, :internal_request

      # Social sign-in exists only where a host asked for it and installed the
      # gems. An application that wants neither Google nor Apple gets no
      # OmniAuth, no callback routes, and nothing to misconfigure.
      if SparrowAuth.config.social?
        enable :omniauth

        omniauth_identities_table :sparrow_auth_account_identities

        SparrowAuth.config.social_providers.each do |provider, options|
          omniauth_provider(provider, *Array(options))
        end
      end

      # Sequel shares Active Record's connection rather than opening a second
      # pool, so a host application has one database configuration and one
      # connection budget instead of two that can disagree. The Sequel adapter
      # has to name the same engine Active Record is connected to, and
      # PostgreSQL or SQLite are the whole world: the installer refuses
      # anything else before any table exists.
      db(
        if ActiveRecord::Base.connection_db_config.adapter.match?(/\Apostg/i)
          Sequel.postgres(extensions: :activerecord_connection, keep_reference: false)
        else
          Sequel.sqlite(extensions: :activerecord_connection, keep_reference: false)
        end
      )

      # Rodauth knows what each of its pages is called; without this the layout
      # has no way to ask, and every built-in page renders as an untitled form.
      title_instance_variable :@page_title

      # Rodauth's default wording puts "Login" on the heading, the field label
      # and the button of the same page, which leaves the field asking for a
      # thing with no name. The field wants an email address, so it says so.
      login_page_title "Sign in"
      login_label "Email address"
      login_button "Sign in"

      create_account_page_title "Create your account"
      create_account_button "Create account"

      verify_account_page_title "Confirm your email address"
      verify_account_button "Confirm email address"
      resend_verify_account_page_title "Resend the confirmation email"
      verify_account_resend_button "Resend confirmation email"
      verify_account_resend_link_text "Resend the confirmation email"

      # Nobody calls it WebAuthn except the specification. Rodauth's defaults
      # put "Setup WebAuthn Authentication" on the heading, the button and the
      # link of a page whose entire job is to say "your device can sign you in
      # from now on".
      webauthn_setup_page_title "Add a passkey"
      webauthn_setup_button "Add a passkey"
      webauthn_setup_link_text "Add a passkey"

      webauthn_auth_page_title "Use your passkey"
      webauthn_auth_button "Use your passkey"
      webauthn_auth_link_text "Use your passkey"

      webauthn_remove_page_title "Remove a passkey"
      webauthn_remove_button "Remove this passkey"
      webauthn_remove_link_text "Remove a passkey"

      # Rodauth's built-in pages render through this, so the engine works when
      # mounted into a bare host application rather than requiring views to be
      # generated first.
      rails_controller { SparrowAuth::RodauthController }

      # Rodauth serves from middleware, above the Rails router, so this is not
      # derived from the engine's mount point and the two must be told to
      # agree. See SparrowAuth::Configuration#path_prefix.
      prefix { SparrowAuth.config.path_prefix }

      # Namespaced tables. An engine that claimed the unqualified `accounts`
      # table would collide with the host application's own, and a silent
      # collision in an auth engine is the worst place to have one.
      accounts_table :sparrow_auth_accounts
      password_hash_table :sparrow_auth_account_password_hashes
      verify_account_table :sparrow_auth_account_verification_keys
      active_sessions_table :sparrow_auth_account_active_session_keys

      webauthn_keys_table :sparrow_auth_account_webauthn_keys
      webauthn_user_ids_table :sparrow_auth_account_webauthn_user_ids

      # Passkeys, the first sign-in method on the ladder.
      #
      # The RP ID is the domain a credential is permanently bound to, and it is
      # stated rather than inferred. Rodauth's default derives it from the
      # origin by stripping scheme and port, so an application served at
      # https://www.example.com would bind every passkey to "www.example.com"
      # and none of them would work on the apex. That is not a mistake a later
      # config change can fix — a credential cannot be moved to a different RP
      # ID — so it is fixed by asking every user to enrol again.
      #
      # Unset, it falls back to Rodauth's derivation, which is correct for
      # localhost and for any host without a www.
      webauthn_rp_id do
        SparrowAuth.config.webauthn_rp_id || super()
      end

      webauthn_rp_name do
        SparrowAuth.config.webauthn_rp_name || super()
      end

      webauthn_origin do
        SparrowAuth.config.webauthn_origin || super()
      end

      # The prompt says who is asking and for whom, because the operating
      # system's dialog shows both and "localhost wants to save a passkey for
      # 12" is not something anyone should be asked to approve.
      webauthn_user_name { account[:email] }

      # Sessions are database-backed from day one, which is what makes them
      # revocable. A session that exists only as a signed cookie cannot be
      # withdrawn, only waited out.
      active_sessions_account_id_column :account_id
      active_sessions_session_id_column :session_id

      # Mandatory verification. There is no configuration switch that turns
      # this off, deliberately: an unverified address is a claim rather than an
      # identity, and every flag of this kind eventually ships enabled in the
      # wrong environment.
      #
      # Note what is NOT enabled above: verify_account_grace_period. That
      # feature exists to let an unverified account log in for a while, and
      # that window is exactly when an unverified address could be used to
      # accept someone else's invitation. Leaving the feature out is stricter
      # than enabling it with a zero grace period, and cannot be widened by a
      # host application setting a number.
      verify_account_set_password? false

      verify_account_email_sent_redirect { login_path }
      verify_account_redirect { login_path }

      # Anti-enumeration. The answer to "does this address have an account?"
      # must be the same whether it does or not, on every path that could be
      # used to ask, and create-account is such a path.
      #
      # Rodauth's default answers a duplicate address with an error, which
      # differs visibly from the redirect a new address gets. That difference is
      # an oracle: it lets anyone enumerate which addresses are registered, one
      # request at a time, without ever signing in.
      #
      # This runs at the top of the route, above the transaction and above
      # Rodauth's catch_error, because a redirect from inside either of those is
      # swallowed and re-rendered as an error page, which is the very response
      # being avoided.
      before_create_account_route do
        login = param(login_param)

        if request.post? && !login.to_s.empty? && account_from_login(login)
          SparrowAuth::Mailer.account_exists(email: login).deliver_now rescue nil # rubocop:disable Style/RescueModifier
          set_notice_flash create_account_notice_flash
          redirect create_account_redirect
        end
      end

      # The same anti-enumeration rule, on the two paths Rodauth serves itself.
      #
      # Rodauth answers a failed sign-in three distinguishable ways: an unknown
      # address gets 401 with the error on the email field, a registered but
      # unverified one gets 403, and a wrong password gets 401 with the error on
      # the password field. Any one of those three differences answers "does
      # this address have an account here". Making only the wording uniform
      # would not close it, because which field carries the error is visible in
      # the markup and the status code is visible without parsing anything.
      #
      # The unverified branch is the sharpest, because Rodauth checks account
      # status *before* it checks the password. Someone who knows nothing but an
      # address learns whether it is registered.
      #
      # So all three answer identically, and the person who owns the address is
      # told what actually happened by email. That is the resolution this engine
      # already settled on for the emailed-code path, applied to the same
      # question here.
      auth_class_eval do
        # The three rules a social sign-in has to obey here. All three come from
        # an audit of an application this was drawn from; the third is the one that
        # application still has.
        #
        # RULE (a) — the provider's own email-verified signal is required before
        # this address counts for anything. An unverified claim is a string the
        # provider passed along, not evidence.
        #
        # RULE (b) — an account created this way gets nothing extra. The bug
        # was `user.permissions = "admin"`, which made every Google sign-in an
        # administrator. This engine has no code path that grants a role at
        # creation at all: roles live in memberships, and provisioning is the
        # host's after_first_signin hook, which every sign-in method reaches the same way.
        # There is nothing to get wrong here, and a spec says so.
        #
        # RULE (c) — linking is asked for, never inferred. See below.

        # The other half of rule (c): the deliberate path.
        #
        # rodauth-omniauth has no notion of "already signed in" — it looks the
        # account up or creates one. Loading the session's account here is what
        # turns the same callback into a connection rather than a sign-in, and
        # it is the only way an identity ever attaches to an account that
        # already existed.
        #
        # The provider's email-verified signal is deliberately not required on
        # this path. Completing the provider's flow is itself the proof, the
        # person is already authenticated here, and the email claim is not used
        # for anything — it is stored so a connections list can say which Google
        # account this is, and never to find an account.
        def before_omniauth_callback_route
          account_from_session if logged_in?

          refuse_identity_owned_by_another_account

          super
        end

        # Connecting a provider account that is already connected somewhere else
        # would leave one identity, two people who believe they own it, and a
        # sign-in that lands on whichever account the row happens to name.
        def refuse_identity_owned_by_another_account
          return unless account

          # Looked up here rather than through the gem's `omniauth_identity`,
          # which is memoised by a retrieval that has not necessarily run yet at
          # this point in the callback. Asking the table directly does not
          # depend on that ordering.
          existing = SparrowAuth::Identity.find_by(
            provider: omniauth_provider.to_s, uid: omniauth_uid.to_s
          )
          return if existing.nil? || existing.account_id == account[account_id_column]

          set_redirect_error_flash omniauth_failure_error_flash
          redirect omniauth_login_failure_redirect
        end

        # Never find an account by email. This is rule (c), and it is one line
        # because the gem's default is the opposite: `_account_from_omniauth`
        # is `_account_from_login(omniauth_email)`, so out of the box anybody
        # who can make a configured provider assert `email_verified` for an
        # address is signed straight into that account.
        #
        # That means the safety of every account rests on the strictness of
        # every provider an application ever adds, forever, including the one
        # somebody enables in a hurry two years from now. A link that has to be
        # asked for reduces a careless provider to reaching only the accounts
        # that deliberately chose it.
        def account_from_omniauth
          nil
        end

        # So the only ways an identity comes to exist are: this provider created
        # the account, or somebody already signed in connected it on purpose.
        def omniauth_create_account?
          return false unless omniauth_email_verified?

          # An address that already has an account is not a free one, and this
          # is where the silent link would otherwise happen. Refused, and the
          # owner is told how to connect it deliberately — the same "uniform on
          # screen, truth in the mailbox" this engine uses everywhere.
          if _account_from_login(omniauth_email)
            notify_owner_of_unconnected_provider
            return false
          end

          true
        end

        # Rule (a). Providers do not agree on where this lives or what type it
        # is: Google sends `info.email_verified` and repeats it under
        # `extra.raw_info`, and an audit recorded seeing it as both a
        # boolean and the string "true". So look in both places and cast rather
        # than trust, and treat anything else as unverified.
        def omniauth_email_verified?
          return false if omniauth_email.to_s.strip.empty?

          info = omniauth_auth["info"] || {}
          raw = info["email_verified"]
          raw = omniauth_auth.dig("extra", "raw_info", "email_verified") if raw.nil?

          ActiveModel::Type::Boolean.new.cast(raw) == true
        end

        def notify_owner_of_unconnected_provider
          address = omniauth_email
          return if address.to_s.strip.empty?
          return unless SparrowAuth::RateLimiter.allow!("login_notice:email" => address.downcase)

          SparrowAuth::Mailer.provider_not_connected(
            email: address,
            provider: omniauth_provider.to_s,
            url: "#{request.base_url}#{SparrowAuth.config.sign_in_path}"
          ).deliver_now
        rescue => e
          Rails.logger.warn("[sparrow_auth] provider_notice_failed class=#{e.class}")
        end

        # Passwords, when a host has asked for them.
        #
        # Off is the default and is a complete configuration rather than a
        # crippled one: an account can be created by code, verified, given a
        # passkey and used, without a password ever existing. Rodauth's login
        # feature still runs — the sign-in page is where passkey autofill lives
        # — so what "off" has to mean is that no password can ever match.
        #
        # Enforced here rather than by hiding the field, because a hidden field
        # is a UI decision and this is an authentication decision. The form does
        # hide it too; that is politeness, and this is the rule.
        def password_match?(password)
          return false unless SparrowAuth.config.passwords_enabled

          super
        end

        def passwords_enabled?
          SparrowAuth.config.passwords_enabled
        end

        # And do not ask for one that cannot work. With passwords off, the
        # sign-in page still exists — it is where passkey autofill lives, and it
        # links to the emailed-code flow — but a field nobody can use is a field
        # that makes people think they have forgotten something.
        def skip_password_field_on_login?
          return true unless SparrowAuth.config.passwords_enabled

          super
        end

        # A password nobody can use is not worth collecting. With the flag off,
        # create-account makes an account with no password at all — the same
        # shape the emailed-code path produces.
        def create_account_set_password?
          SparrowAuth.config.passwords_enabled
        end

        def password_minimum_length
          SparrowAuth.config.password_minimum_length
        end

        # The hook point, not the implementation. Checking a password against a
        # breach corpus means shipping the corpus or calling somebody else's
        # service, and an auth engine should not make that choice for an
        # application. Unset, nothing is checked and nothing pretends to be.
        def password_meets_requirements?(password)
          return false unless super

          breached = SparrowAuth.config.password_breached
          return true if breached.nil?

          if breached.call(password)
            @password_requirement_message = "has appeared in a data breach and cannot be used"
            return false
          end

          true
        end

        # Multi-phase login, off.
        #
        # webauthn_login turns sign-in into two steps: type an address, then be
        # shown what that address can use. It is a nicer flow and it is an
        # enumeration oracle by construction — a registered address advances to
        # a second page, an unknown one gets an error on the first, and the two
        # pages are not remotely alike. Rodauth also renders the passkey form
        # there only when that account has a passkey, which answers a second
        # question nobody should be able to ask.
        #
        # Nothing about that can be made uniform by configuration, so it is not
        # used. Passkeys instead go through webauthn_autofill, where the browser
        # offers a discoverable credential and no address is typed at all — the
        # flow the platforms actually recommend, and one with no enumeration
        # surface because there is nothing to enumerate against.
        #
        # The cost, stated plainly: somebody whose browser lacks conditional UI
        # cannot reach a passkey by typing their address. They use the emailed
        # code or a password. Offering that fallback would mean answering, for
        # any address, whether it exists and whether it has a passkey.
        def use_multi_phase_login?
          false
        end

        # The unverified case does not travel the same road as the other two.
        # Rodauth's verify_account feature overrides before_login_attempt and
        # answers with `return_response resend_verify_account_view` — not a
        # different message on the login page but a different page entirely,
        # under a different status. Configuring messages could never have
        # reached it; this is the seam where that decision is actually made.
        #
        # The account still does not get in. Only the answer changes.
        # The clock was answering the question the page refused to.
        #
        # An address with no account threw before any password work happened; an
        # address with one paid for a bcrypt comparison first. Measured over
        # HTTP, the account path cost roughly forty times the other, in the same
        # direction every time — a complete account-enumeration oracle sitting
        # underneath responses that are byte-identical. (Ratios, not
        # milliseconds: the absolute numbers belong to whatever machine took
        # them.)
        #
        # So the path with no account does the same work. The comparison is
        # against a hash of a value nothing can match, generated once at the
        # same cost as a real one, and its result is discarded.
        #
        # This equalises the dominant cost, not every cost: the database lookup
        # still differs, and bcrypt's own duration varies a little with input.
        # It moves the signal from "obvious to anybody" to "needs statistics and
        # a lot of samples", and the throttle above limits how many samples
        # anybody gets. That is a real improvement and not a proof.
        def after_no_matching_login
          spend_a_password_comparison

          super
        end

        # The comparison is the whole point and its answer is worthless, which
        # reads to a linter as an operator in void context. Returning it from a
        # method says the same thing without the pretence that anybody cares
        # what it was.
        #
        # password_hash_cost is Rodauth's, so if an application raises it the
        # decoy rises with it and the two paths keep costing the same.
        def spend_a_password_comparison
          decoy = SparrowAuth::RodauthMain.decoy_password_hash(password_hash_cost)

          BCrypt::Password.new(decoy) == param(password_param).to_s
        end

        def before_login_attempt
          refuse_if_password_attempts_exhausted

          unless open_account?
            notify_unverified_account_owner
            throw_error_reason(:unverified_account, login_error_status, login_param,
              SparrowAuth::RodauthMain::LOGIN_FAILURE_MESSAGE)
          end

          super
        end

        # Password guessing, throttled.
        #
        # This throttles the password *path*, not the account. Somebody whose
        # address is being worked through a word list can still sign in
        # immediately with an emailed code or a passkey, so the denial of
        # service an attacker can inflict costs their victim nothing they cannot
        # route around — which is what makes an expiring lockout acceptable here
        # at all.
        #
        # The budget is keyed on the stored address rather than the submitted
        # one, so varying capitalisation cannot buy a fresh allowance. That is
        # the same mistake that would have made the send budget worthless, found
        # by mutation testing an hour before this was written.
        #
        # The refusal goes out through the same throw as a wrong password, so a
        # throttled attempt and a wrong one are one response. Rodauth's own
        # lockout feature announces itself, which would answer "does this
        # address have an account here" out loud on every locked account.
        def refuse_if_password_attempts_exhausted
          return if SparrowAuth::RateLimiter.allowed?(
            bucket: "login:email", subject: throttled_login_subject
          ) && SparrowAuth::RateLimiter.allowed?(
            bucket: "login:ip", subject: request.ip
          )

          notify_password_attempts_throttled

          throw_error_reason(:invalid_password, login_error_status, password_param,
            SparrowAuth::RodauthMain::LOGIN_FAILURE_MESSAGE)
        end

        # Counted on failure only. A budget spent by signing in correctly would
        # lock somebody out of their own account for using it.
        def after_login_failure
          SparrowAuth::RateLimiter.record(bucket: "login:email", subject: throttled_login_subject)
          SparrowAuth::RateLimiter.record(bucket: "login:ip", subject: request.ip)

          super
        end

        def throttled_login_subject
          account && account[login_column].to_s.strip.downcase
        end

        # Once an hour at most. A message sent on every refused attempt would
        # turn the sign-in form into a way to mail somebody continuously, which
        # is the attack this is supposed to be reporting.
        def notify_password_attempts_throttled
          address = throttled_login_subject
          return if address.blank?
          return unless SparrowAuth::RateLimiter.allow!("login_notice:email" => address)

          SparrowAuth::Mailer.password_attempts_throttled(
            email: address,
            url: "#{request.base_url}#{SparrowAuth.config.path_prefix}/webauthn-setup"
          ).deliver_now
        rescue => e
          Rails.logger.warn("[sparrow_auth] throttle_notice_failed class=#{e.class}")
        end

        # The last thing on this page that still knew the answer.
        #
        # Rodauth shows "resend the confirmation email" in the login footer only
        # when the submitted address is registered, unverified and resendable.
        # One line of HTML, appearing for exactly the addresses in that state,
        # is a complete enumeration oracle — and the one this engine missed on
        # the first pass, because it only appears once a matching account really
        # exists, which a probe with no accounts set up cannot see.
        #
        # The link now always renders. It points at a page anyone may visit, so
        # its presence tells nobody anything they could not already learn by
        # typing the URL, and the person who genuinely needs it can find it.
        def _login_form_footer_links
          links = super

          unless links.any? { |(_, path, _)| path == verify_account_resend_path }
            links << [30, verify_account_resend_path, verify_account_resend_link_text]
          end

          # A way out of a dead end. An account created by code has no password,
          # and if it has not enrolled a passkey yet there is nothing on this
          # page it can use — the form asks for a password it does not have and
          # the browser has no credential to offer. The code flow is the sign-in method it
          # actually signs in with, and it was reachable only by typing the URL.
          #
          # Shown to everybody, like the resend link, because which links appear
          # must not depend on who is asking.
          sign_in_path = SparrowAuth.config.sign_in_path
          unless links.any? { |(_, path, _)| path == sign_in_path }
            links << [10, sign_in_path, "Email me a code instead"]
          end

          links
        end

        # Recorded when the session row is created, which is the only moment
        # the request that started it is in hand.
        def active_sessions_insert_hash
          super.merge(user_agent: request.user_agent.to_s[0, 255])
        end

        # Every sign-in method ends up here.
        #
        # Rodauth's `after_login` would miss the emailed-code path, which calls
        # `login_session` directly rather than going through the password
        # route — and a first-signin hook that fires for some ways of signing in
        # and not others is worse than none, because the application cannot tell
        # which accounts were provisioned. Passkeys and social sign-in arrive in
        # later phases through the same method.
        def login_session(auth_type)
          super

          SparrowAuth.record_first_signin(rails_account)
        end

        def throw_error_reason(reason, status, field, message)
          unless request.path == login_path &&
              SparrowAuth::RodauthMain::UNIFORM_LOGIN_FAILURES.include?(reason)
            return super
          end

          super(reason, login_error_status, login_param,
            SparrowAuth::RodauthMain::LOGIN_FAILURE_MESSAGE)
        end

        # Only when the password was right.
        #
        # A correct password is the only evidence available on this path that
        # the person typing owns the address. Notifying on every attempt would
        # turn the sign-in form into a way to send someone mail repeatedly while
        # knowing nothing about their account, which is the same endpoint abuse
        # the rate limits elsewhere in this engine exist to prevent.
        def notify_unverified_account_owner
          return unless password_match?(param(password_param))

          SparrowAuth::Mailer.verification_needed(
            email: account[login_column],
            url: "#{request.base_url}#{SparrowAuth.config.path_prefix}/verify-account-resend"
          ).deliver_now
        rescue => e
          # Swallowed, for the same reason the OTP path swallows send failures:
          # an error that reached the screen would be an oracle of its own, and
          # one that only appears when a provider is having a bad day. Logged
          # without the body.
          Rails.logger.warn("[sparrow_auth] unverified_login_notice_failed class=#{e.class}")
        end
      end

      # Resending a confirmation email answers three ways too: a registered
      # unverified address gets a notice and one redirect target, a recently
      # sent one gets a different message, and an unknown or already-verified
      # address gets "Unable to resend verify account email" at another target.
      # Even identical wording would still differ by flash key, which this
      # engine's layout renders as red rather than grey.
      #
      # Handled here rather than by configuring the messages, for the same
      # reason create-account is: one response, built in one place, for every
      # branch. Rodauth's own 300-second per-account resend window still applies
      # underneath, so this cannot be used to send someone mail in a loop.
      before_verify_account_resend_route do
        if request.post?
          login = param(login_param)

          begin
            if !login.to_s.empty? && account_from_login(login) &&
                allow_resending_verify_account_email? && !verify_account_email_recently_sent?
              before_verify_account_email_resend
              verify_account_email_resend
              after_verify_account_email_resend
            end
          rescue => e
            # A send failure that escaped would be a 500 here and a redirect
            # everywhere else, so a provider outage would answer the enumeration
            # question for exactly the addresses it applies to.
            Rails.logger.warn("[sparrow_auth] verify_account_resend_failed class=#{e.class}")
          end

          set_notice_flash SparrowAuth::RodauthMain::RESEND_NOTICE
          redirect login_path
        end
      end

      email_auth_table :sparrow_auth_email_auth_keys

      # Ten minutes, matching the code flow. Rodauth's default is one day, which
      # is a long time for a working key to sit in a mailbox -- and a mailbox is
      # exactly where the other person is if this has gone wrong.
      email_auth_deadline_interval seconds: SparrowAuth.config.emailed_sign_in_link_expiry

      # Through sparrow_mail like every other message this engine sends, for the
      # same two reasons: the body is never logged, and a failed send is never
      # retried into a second live token.
      send_email_auth_email do
        SparrowAuth::Mailer.sign_in_link(
          email: email_to,
          url: email_auth_email_link
        ).deliver_now
      end

      # Rodauth's own wording for the page somebody lands on from the link.
      # "Login" as a heading on a page whose only control is a button reads like
      # a form somebody has failed to fill in.
      #
      # The button there is `login_button`, already named further up -- the
      # template renders that rather than one of its own.
      email_auth_page_title "Finish signing in"

      # Auth email is sent through sparrow_mail rather than Rodauth's own
      # mailer, so the two inviolable rules apply to it: the body is never
      # logged, and a failed send is never retried into a second live token.
      send_verify_account_email do
        SparrowAuth::Mailer.verify_account(
          email: email_to,
          url: verify_account_email_link
        ).deliver_now
      end

      # Provisioning hooks. The engine provides the moment; the application
      # decides what happens at it.
      #
      # after_verification was exposed and documented in Phase 1 and never
      # actually called — the kind of gap that stays invisible because nothing
      # fails, the hook simply never runs and the application quietly has no
      # personal organizations. It fires here now.
      after_verify_account do
        SparrowAuth.run_hook(:after_verification, rails_account)
      end

      # The ActiveRecord view of the same rows, for everything that is not an
      # auth ceremony.
      rails_account_model { SparrowAuth::Account }
    end
  end
end
