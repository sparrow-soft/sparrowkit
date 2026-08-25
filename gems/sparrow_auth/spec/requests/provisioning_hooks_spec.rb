# frozen_string_literal: true

require "rails_helper"
require "uri"

# Provisioning hooks, driven through real sign-ins rather than by calling the
# hook runner directly.
#
# What an application depends on is *when* these fire, and that is decided by
# the plumbing — which Rodauth method a sign-in method goes through, whether
# a second sign-in looks like a first. A spec that called the hook itself would
# prove none of it.
RSpec.describe "provisioning hooks", type: :request do
  let(:email) { "newcomer@example.org" }
  let(:password) { "correct horse battery staple" }

  def create_account(address = email)
    post "/auth/create-account", params: {
      login: address, password: password, "password-confirm": password
    }
  end

  def verify_account
    url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
    key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
    get url
    # GET first, the way somebody clicking the emailed link does. Rodauth 2.47
    # takes the key from the session that GET establishes rather than from the
    # POST body, so a POST on its own is refused -- and a POST on its own is not
    # a thing a browser ever does.
    get "/auth/verify-account", params: {key: key}
    post "/auth/verify-account", params: {key: key}
  end

  def sign_in(address = email)
    post "/auth/login", params: {login: address, password: password}
  end

  def sign_out
    post "/auth/logout"
  end

  describe "after_verification" do
    # Exposed and documented in Phase 1, and never actually called. Nothing
    # failed; the hook simply never ran, which is exactly why it went unnoticed.
    it "fires when an account verifies" do
      seen = []
      SparrowAuth.config.after_verification = ->(account) { seen << account.email }

      create_account
      verify_account

      expect(seen).to eq([email])
    end
  end

  # The out-of-the-box path, and the reason it is a default rather than a line
  # somebody uncomments: an application that installs sparrow_auth and does
  # nothing else could sign in, and then hit UnscopedQuery on the first
  # Tenanted model it wrote, because the account belonged to no organization.
  # By default a new account belongs to NOTHING.
  #
  # It used to be given an organization it owned, and that default arrived in
  # 2.0.0 without being written down. Owning an organization carries
  # organization:delete, organization:transfer, members:manage and
  # billing:manage, plus the standing to invite anybody at any role -- handed to
  # everybody who signed up, on a product that may well seat people by
  # invitation only.
  #
  # PERSONAL_ORGANIZATION is still there for products where signing up does mean
  # starting your own workspace. It is now something an application asks for.
  describe "the organization a new account gets by default" do
    it "gives them none, so standing is something an application grants" do
      create_account
      verify_account

      expect(SparrowAuth::Account.find_by_email(email).memberships).to be_empty
    end

    it "makes exactly one when an application asks for the personal-organization hook" do
      SparrowAuth.config.after_first_signin = SparrowAuth::Configuration::PERSONAL_ORGANIZATION

      create_account
      verify_account
      sign_out
      sign_in
      sign_out
      sign_in

      account = SparrowAuth::Account.find_by_email(email)
      expect(account.memberships.count).to eq(1)
      expect(account.memberships.sole.role).to eq("owner")
    end

    # Not the address. derive_slug parameterizes the name, so an email would put
    # "alice-example-com" in every URL that names the organization.
    it "does not name that organization after the person's email address" do
      SparrowAuth.config.after_first_signin = SparrowAuth::Configuration::PERSONAL_ORGANIZATION

      create_account
      verify_account

      organization = SparrowAuth::Account.find_by_email(email).memberships.sole.organization
      expect(organization.name).not_to include("@")
    end

    it "steps aside for an application that provisions its own way" do
      SparrowAuth.config.after_first_signin = ->(account) { account }

      create_account
      verify_account

      expect(SparrowAuth::Account.find_by_email(email).memberships).to be_empty
    end

    it "can be switched off entirely" do
      SparrowAuth.config.after_first_signin = nil

      create_account
      verify_account

      expect(SparrowAuth::Account.find_by_email(email).memberships).to be_empty
    end
  end

  describe "after_first_signin" do
    it "fires when the account first signs in" do
      seen = []
      SparrowAuth.config.after_first_signin = ->(account) { seen << account.email }

      create_account
      verify_account
      sign_out
      sign_in

      expect(seen).to eq([email])
    end

    # Verification signs the account in, so an implementation that fired on
    # "any session appearing" would double-provision every account it ever saw.
    it "fires exactly once across several sign-ins" do
      seen = []
      SparrowAuth.config.after_first_signin = ->(account) { seen << account.email }

      create_account
      verify_account
      sign_out
      sign_in
      sign_out
      sign_in

      expect(seen).to eq([email])
    end

    # Two sessions starting at once both read a null first_signed_in_at, and a
    # read-then-write would run the hook twice — two personal organizations for
    # one person, from a race nobody can reproduce afterwards.
    #
    # The stale copy is the race, made deterministic: both objects hold the null
    # they were loaded with, exactly as two concurrent requests would.
    it "fires once when two sign-ins race on the same account" do
      seen = []
      create_account
      verify_account
      SparrowAuth::Account.where(email: email).update_all(first_signed_in_at: nil)
      SparrowAuth.config.after_first_signin = ->(account) { seen << account.email }

      one = SparrowAuth::Account.find_by_email(email)
      two = SparrowAuth::Account.find_by_email(email)

      SparrowAuth.record_first_signin(one)
      SparrowAuth.record_first_signin(two)

      expect(seen).to eq([email])
    end

    it "records when it happened, so the event is a fact rather than a guess" do
      create_account
      verify_account

      expect(SparrowAuth::Account.find_by_email(email).first_signed_in_at).to be_present
    end

    # A first-signin hook that fires for some sign-in methods and not others is worse
    # than none, because the application cannot tell which accounts were
    # provisioned. So it is not hung off Rodauth's `after_login`, which only the
    # password route reaches — it is on `login_session`, which every sign-in
    # method goes through, including the emailed-code screen.
    #
    # This used to drive that screen over HTTP. The screen is the application's now,
    # and the property has split cleanly in two: the examples above prove
    # `login_session` fires the hook, and the generator specs prove the sign-in
    # screen signs people in by calling `login_session` rather than by writing
    # a session key of its own. Both halves are asserted; neither is here.
    it "hangs off login_session, which every sign-in method reaches" do
      expect(SparrowAuth::RodauthMain.instance_methods(false)).to include(:login_session)
    end
  end

  # Gate 3 asks for a hook the host application actually implements, exercised
  # by the suite. PersonalOrganizationProvisioner lives in the dummy app: it is
  # One earlier application's system-organization logic and another earlier application's auto-org, in the place the
  # brief says they belong.
  describe "a host application's own provisioning" do
    before { SparrowAuth.config.after_first_signin = PersonalOrganizationProvisioner }

    it "gives a new account its own organization, owned by them" do
      create_account
      verify_account

      account = SparrowAuth::Account.find_by_email(email)
      organization = account.organizations.sole

      expect(organization.name).to eq("newcomer's workspace")
      expect(account.role_in(organization)).to eq("owner")
    end

    it "does not give them a second one on a later sign-in" do
      create_account
      verify_account
      sign_out
      sign_in

      expect(SparrowAuth::Account.find_by_email(email).organizations.count).to eq(1)
    end

    # The engine knows a first sign-in happened. It does not know, and must not
    # decide, what that means for a given product.
    it "leaves the engine with no opinion when no hook is configured" do
      SparrowAuth.config.after_first_signin = nil

      create_account
      verify_account

      expect(SparrowAuth::Account.find_by_email(email).organizations).to be_empty
    end
  end
end
