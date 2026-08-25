# frozen_string_literal: true

module SparrowAuth
  # What a host application may change.
  #
  # Note what is absent. There is no setting to disable email verification, and
  # there will not be one. Every application that has ever added such a flag has
  # eventually shipped with it off somewhere, and an unverified address is the
  # difference between an invitation and a hijacked account.
  #
  # Where applications genuinely differ, this exposes hooks and values rather
  # than branching on which application is asking.
  class Configuration
    # Where Rodauth serves its routes.
    #
    # Rodauth runs as middleware rather than through the Rails router, so its
    # paths are not derived from wherever the engine is mounted. The two have to
    # be told to agree. This defaults to the same place the engine is normally
    # mounted, and a host that mounts elsewhere must set this to match.
    attr_accessor :path_prefix

    # Where YOUR sign-in screen lives.
    #
    # Rodauth's own pages link to it twice -- "Email me a code instead" in the
    # sign-in footer, and the email sent when somebody tries a social provider
    # they have not connected. Both are the way out for an account that has no
    # password and no passkey, which is the ordinary state of an account created
    # by an emailed code.
    #
    # The engine cannot know the path, because the screen is yours: it is
    # written into your application by you. SparrowKit ships no screens.
    # The default is what that generator draws. Change this if you move it, and
    # the two links follow.
    #
    # It defaulted to the engine's own /auth/otp until 0.1.0, when that page
    # stopped existing -- leaving both links pointing at a 404 and an account
    # with no other way in.
    attr_accessor :sign_in_path

    # Where the second step of that screen lives -- the one asking for the code
    # itself. Only the test helpers need it, and only because they walk both
    # steps the way a person does.
    #
    # Derived from sign_in_path rather than stored, so moving the screen moves
    # both halves and there is no second setting to forget.
    attr_writer :sign_in_code_path

    def sign_in_code_path
      @sign_in_code_path || "#{sign_in_path}/code"
    end

    # How long a verification link stays usable. Long enough to survive a
    # forwarded-to-phone round trip, short enough that a leaked mailbox backup
    # is not a standing key.
    attr_accessor :verify_account_expiry

    # The key one-time code digests are HMAC'd with. Left unset it is derived
    # through Rails' key generator, which gives a stable secret distinct from
    # every other derived key, so a leak of one does not compromise the others.
    attr_accessor :otp_secret

    # How long an invitation stays usable.
    attr_accessor :invitation_expiry

    # Where to send someone after they accept an invitation. A path rather than
    # a route helper, because the engine does not know what routes a host has
    # and must not fall over if it has no root.
    attr_accessor :after_accept_path

    # The address auth mail is sent from. Falls back to sparrow_mail's own
    # default_from when unset.
    attr_accessor :mail_from

    # Auth mail is transactional by definition, and must never ride a bulk
    # sending reputation. Exposed only so an application with an unusual stream
    # layout can name it, not so it can be turned off.
    attr_accessor :mail_stream

    # Called with the account after it verifies for the first time. Where a host
    # application creates its own records: a personal organization, a profile,
    # a trial. The engine does not know what any of those are.
    attr_accessor :after_verification

    # Called with (account, invitation) after an invitation is accepted.
    attr_accessor :after_invitation_accepted

    # Who may issue an invitation, and at what role.
    #
    #   config.authorize_invitation = lambda do |inviter:, organization:, role:|
    #     inviter.membership_in(organization)&.role == "owner"
    #   end
    #
    # Returns true to allow. Nil -- the default -- refuses every invitation into
    # an organization, on purpose: see Invitation.check_the_invitation_ceiling!.
    attr_accessor :authorize_invitation

    # Called with the account the first time it signs in, by any sign-in method of the
    # ladder, and never again. Fires after the session exists, so the hook can
    # act on behalf of somebody who is genuinely there.
    #
    # This is the hook a system-organization rule, or an automatic organization
    # per account,
    # belong in. Both are provisioning *rules* — which organization a new person
    # lands in, and whether one is made for them — and both are specific to
    # those products. The engine provides the moment; the application decides
    # what happens at it.
    # What a brand new account gets when nobody has said otherwise: an
    # organization of its own, which it owns.
    #
    # A default rather than a line in the generated initializer waiting to be
    # uncommented. Without it, installing sparrow_auth and doing nothing else
    # gets you an account that can sign in and belongs to no organization —
    # and the first Tenanted model you write then raises UnscopedQuery, which
    # reads like a bug in the gem rather than a step nobody told you about.
    #
    # This is not the engine knowing what an application's data looks like.
    # SparrowAuth::Organization is the engine's own model; a profile row or a
    # trial would not be, and neither has a default here.
    #
    # Replaced by assignment, so an application that provisions differently
    # simply sets its own and this never runs. `nil` switches it off and leaves
    # the account belonging to nothing, which is a coherent choice for an
    # application that will seat people by invitation only.
    #
    # The guard is not ceremony. `after_first_signin` fires once by contract,
    # but this is the one hook whose double-firing would be invisible: a second
    # organization nobody asked for, that the person is also the owner of.
    # Opt-in, not the default:
    #
    #   config.after_first_signin = SparrowAuth::Configuration::PERSONAL_ORGANIZATION
    #
    # For a product where signing up means starting your own workspace. It is
    # the wrong default for one where people are invited into an organization
    # that already exists, and being wrong that way hands every new account
    # owner-level standing over a tenant.
    #
    # The name is deliberately neutral rather than the account's address, which
    # derive_slug would turn into "alice-example-com" in every URL that names
    # the organization.
    PERSONAL_ORGANIZATION = lambda do |account|
      next if account.memberships.any?

      SparrowAuth::Organization.create_with_owner!(account: account, name: "My organization")
    end

    attr_accessor :after_first_signin

    # Called with (organization, created_by) after an organization is created.
    attr_accessor :after_organization_created

    attr_accessor :social_providers

    # Whether redeeming an emailed code for an address with no account creates
    # one, verified and without a password.
    #
    # On by default, because it is the shortest honest path to an account: the
    # code proves control of the mailbox, which is the only thing the account
    # ever needed to prove, and nothing along the way invents a password for
    # somebody to reuse, forget or have breached elsewhere. It is also at least
    # as strong as the confirmation link it replaces — a link can be consumed by
    # a scanner that prefetches it, and several mail providers rewrite links
    # through their own click tracking; a six-digit code typed by a person
    # cannot be consumed by anything that merely reads the message.
    #
    # Turn it off for an invite-only product, where an address arriving at the
    # sign-in page should not become an account.
    attr_accessor :signup_with_code

    # The key API token digests are HMAC'd with. Left unset it is derived
    # through Rails' key generator, like the one-time code secret.

    # Which shape emailed sign-in takes: a code somebody types, or a link they
    # open.
    #
    #   config.emailed_sign_in = :code   # the default
    #   config.emailed_sign_in = :link
    #
    # ONE OR THE OTHER, ALWAYS. There is no way to have both and no way to have
    # neither, and neither omission is an oversight. Both would be two ways into
    # the same account for no benefit, and each way in is a thing that can go
    # wrong. Neither would be an application nobody can get into: passkeys are
    # always on, but an account that has just been created has no passkey, so
    # emailed sign-in is the only door that is open to somebody arriving for the
    # first time.
    #
    # Which to choose:
    #
    #   :code   Six digits, typed on the page they were asked for. Works when
    #           the mail is read somewhere else -- a phone, a shared mailbox,
    #           a password manager on another machine.
    #
    #   :link   One click. Faster when the mail is read on the same device, and
    #           it CANNOT be finished anywhere else: Rodauth stores the key in
    #           the session on the way past, so the browser that opens the link
    #           must be the browser that asked for it. That is not a limitation
    #           to work around -- it is what stops a mail scanner that prefetches
    #           links from signing somebody in, or from burning the link before
    #           they get to it.
    #
    # The trade is real and it is the reason both exist. Neither is more secure
    # than the other; they fail in different places.
    #
    # attr_WRITER, not accessor: the reader is written out below, so that a
    # value nothing recognises raises rather than quietly becoming "no emailed
    # sign-in at all" -- the one state this setting must not be able to express.
    attr_writer :emailed_sign_in

    # How long a sign-in link stays usable.
    #
    # Ten minutes, matching the code flow, so there is one number to explain
    # rather than two. Rodauth's own default is ONE DAY, which is a long time
    # for a live key sitting in a mailbox.
    attr_accessor :emailed_sign_in_link_expiry

    # Whether passwords are a way in at all.
    #
    # Off by default, which is what the auth ladder always intended: a password
    # is the weakest sign-in method and the only one that can be guessed, phished or
    # reused. An account can be created, verified and used without one ever
    # existing, so "off" is a complete configuration rather than a crippled one.
    #
    # Turn it on for an application whose users expect a password. The other
    # sign-in methods keep working either way.
    attr_accessor :passwords_enabled

    # Minimum password length when passwords are enabled. Twelve
    # and is above every current floor worth having.
    attr_accessor :password_minimum_length

    # Called with a candidate password before it is accepted, if set. Return
    # true to refuse it.
    #
    # A hook rather than an implementation, because checking a password against
    # a breach corpus means either shipping the corpus or calling somebody
    # else's service, and an auth engine should not decide which on an
    # application's behalf. Have It Been Pwned's range API is the usual answer.
    attr_accessor :password_breached

    # The origin passkeys are registered against, e.g. "https://example.com".
    # Left unset it is derived from the request, which is right in development
    # and wrong behind a proxy that terminates TLS.
    attr_accessor :webauthn_origin

    # The WebAuthn Relying Party ID — the domain a credential is bound to.
    #
    # Set this deliberately. Rodauth derives it from the origin by stripping the
    # scheme and port, so an application served at https://www.example.com gets
    # the RP ID "www.example.com", and every passkey enrolled under it will fail
    # on https://example.com. A credential is bound to the RP ID it was created
    # under and cannot be migrated to another, so this is not a mistake that can
    # be corrected later by changing a setting: it is corrected by asking every
    # user to enrol again.
    #
    # The registrable domain — "example.com" — is almost always what you want,
    # because it works on the apex and on every subdomain.
    #
    # Usually nobody sets this. Left alone it is the host of the application's
    # own address, asked for once on the control panel's front page, so the
    # domain cannot be answered two ways on two pages. Setting it here is an
    # override, for the case where the passkey domain genuinely differs from the
    # address — an application served at www.example.com wanting passkeys to
    # work on the apex and every other subdomain, which is the common one.
    #
    # Still nil when neither is set, and that is deliberate: WebAuthn then reads
    # the domain off the request being answered, which is right for a
    # development machine and wrong to rely on in production.
    attr_writer :webauthn_rp_id

    def webauthn_rp_id
      (@webauthn_rp_id || SparrowAuth.application_host)&.downcase
    end

    # Whether the id passkeys would bind to is WIDER than the host serving the
    # request -- an apex where the application runs on a subdomain.
    #
    # This is worth asking because the value is inherited from the control
    # panel's address box, which also means "where mail links point" and "where
    # a processor returns a customer". For those, an operator running at
    # app.example.com may quite reasonably type the apex. For this one it is not
    # reasonable at all: a passkey scoped to example.com is valid across every
    # subdomain, so whoever takes over blog.example.com or a dangling CNAME can
    # mount a ceremony the authenticator will satisfy.
    #
    # A browser accepts it, which is what makes it quiet. Nothing fails, and the
    # scope is wrong for the life of every credential enrolled.
    #
    # Returns nil when there is nothing to say.
    def webauthn_rp_id_widens?(request_host)
      configured = webauthn_rp_id
      host = request_host.to_s.downcase.presence
      return false if configured.nil? || host.nil? || configured == host

      # A proper suffix on a label boundary: "example.com" widens "app.example.com".
      host.end_with?(".#{configured}")
    end

    # What the passkey prompt calls this application. The person enrolling sees
    # it in their operating system's dialog, so it should be the product's name
    # rather than a hostname.
    #
    # Usually nobody sets this either. Left alone it is the product's name, asked
    # for once on the control panel's front page beside the address, for the same
    # reason: it is one fact about the product, and a second box asking for it
    # again is a second answer waiting to disagree with the first.
    #
    # Nil when neither is set, and WebAuthn then shows the host — which reads
    # like a machine talking, and is why the panel asks.
    attr_writer :webauthn_rp_name

    def webauthn_rp_name
      @webauthn_rp_name || SparrowAuth.application_name.presence
    end

    # How to work out which organization the current request is for.
    #
    # Called with the controller. Returning nil means no organization is in
    # scope, which is not an error by itself — a sign-in page has no tenant —
    # but any tenant-scoped query made in that state will raise.
    #
    # The default answers in the order an application usually wants: an explicit
    # choice held in the session, then the account's only membership if it has
    # exactly one. It never guesses between several, because picking one for
    # somebody who belongs to three is how a person ends up writing into the
    # wrong tenant without being told.
    #
    # Renamed in 0.1.0. Its old name shared a word with the per-record policy
    # object that release deleted, and the two were never the same thing -- that
    # one decided who may do what, this one only answers which tenant a request
    # is for. One word meaning two things is how the other survived deletion in
    # four places. This name says what it does.
    attr_accessor :organization_for_request

    def initialize
      @path_prefix = "/auth"
      @sign_in_path = "/sign-in"
      @verify_account_expiry = 86_400
      @invitation_expiry = 7 * 86_400
      @otp_secret = nil
      @after_accept_path = "/"
      @mail_from = nil
      @mail_stream = :transactional
      @after_verification = nil
      @after_invitation_accepted = nil
      # nil, not PERSONAL_ORGANIZATION.
      #
      # 2.0.0 flipped this default without saying so -- it is not in the
      # changelog, which documents four other breaking changes. The effect was
      # that everybody who signed in became the OWNER of a new organization,
      # holding organization:delete, organization:transfer, members:manage and
      # billing:manage, with an invite ceiling of :owner. Nobody granted that.
      #
      # It also named the organization after the account's email, which
      # derive_slug turns into "alice-example-com" in every URL.
      #
      # Seeding creates the one organization a developer needs to test with.
      # What happens to the NEXT account is an application's decision, and an
      # engine guessing at it hands out standing nobody asked for.
      @after_first_signin = nil
      @after_organization_created = nil
      @organization_for_request = nil
      @signup_with_code = true
      @social_providers = {}
      @passwords_enabled = false
      @emailed_sign_in = :code
      @emailed_sign_in_link_expiry = 600
      @password_minimum_length = 12
      @password_breached = nil
      @webauthn_origin = nil
      @webauthn_rp_id = nil
      @webauthn_rp_name = nil
    end

    # Social sign-in needs both a host that asked for it and the gems to do it.
    # Either missing means the feature does not exist, rather than existing and
    # failing at the callback.
    # The two shapes emailed sign-in comes in.
    EMAILED_SIGN_IN = %i[code link].freeze

    # Read rather than stored, so that a value nothing recognises cannot quietly
    # become "no emailed sign-in at all" -- which is the one state this setting
    # is not allowed to express.
    #
    # Raising instead. A typo in an initializer is a typo somebody can fix in
    # the second it takes to read the message; an application that silently
    # locked everybody out because `:links` is not `:link` is a support ticket
    # that starts "nobody can sign in and nothing changed".
    def emailed_sign_in
      value = @emailed_sign_in.to_s.strip.downcase.to_sym
      return value if EMAILED_SIGN_IN.include?(value)

      raise Error,
        "#{@emailed_sign_in.inspect} is not a way of signing in by email. " \
        "It is #{EMAILED_SIGN_IN.map(&:inspect).join(" or ")}, and never both or neither."
    end

    def emailed_sign_in_link? = emailed_sign_in == :link

    def emailed_sign_in_code? = emailed_sign_in == :code

    def social?
      return false if social_providers.nil? || social_providers.empty?

      # rodauth-omniauth ships feature files rather than an entry point, so
      # there is no constant to test for — Rodauth loads a feature by name off
      # the load path when `enable :omniauth` runs.
      #
      # Looked for rather than required: requiring a Rodauth feature directly
      # runs `Feature.define` outside the loader that is supposed to call it,
      # which raises. Asking whether the file exists answers the same question
      # and executes nothing, so a host that configured providers without
      # installing the gem gets no social sign-in rather than a callback route
      # that raises on the first visitor.
      $LOAD_PATH.any? { |dir| File.exist?(File.join(dir, "rodauth", "features", "omniauth.rb")) }
    end

    def inspect
      "#<SparrowAuth::Configuration verify_account_expiry=#{verify_account_expiry} " \
        "invitation_expiry=#{invitation_expiry} mail_stream=#{mail_stream.inspect}>"
    end
    alias_method :to_s, :inspect
  end
end
