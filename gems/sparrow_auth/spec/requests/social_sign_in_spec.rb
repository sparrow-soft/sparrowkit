# frozen_string_literal: true

require "rails_helper"

# Social sign-in, and the three rules it obeys.
#
# All three come from a security audit of an earlier application. Two of the
# findings were fixed there and this engine inherits the fix; the third is the
# reason this file is written from the attacker's side.
#
# The provider here is OmniAuth's developer strategy standing in for Google and
# Apple. What is under test is provider-independent: what this engine will and
# will not do with what a provider asserts.
RSpec.describe "signing in with a provider", type: :request do
  let(:password) { "correct horse battery staple" }

  before do
    OmniAuth.config.test_mode = true
    OmniAuth.config.mock_auth.clear
  end

  after { OmniAuth.config.mock_auth.clear }

  def provider_says(email:, verified: true, uid: "provider-uid-1", raw: false)
    info = {email: email}
    extra = {}
    if raw
      extra = {raw_info: {email_verified: verified}}
    else
      info[:email_verified] = verified
    end

    OmniAuth.config.mock_auth[:developer] = OmniAuth::AuthHash.new(
      provider: "developer", uid: uid, info: info, extra: extra
    )
  end

  def sign_in_with_provider
    post "/auth/auth/developer"
    follow_redirect!
  end

  def account_for(email)
    SparrowAuth::Account.find_by_email(email)
  end

  def sessions_for(account)
    return 0 if account.nil?

    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
      "WHERE account_id = #{account.id.to_i}"
    )
  end

  def register_and_verify(address)
    post "/auth/create-account", params: {
      login: address, password: password, "password-confirm": password
    }
    SparrowAuth::Account.where(email: address)
      .update_all(status_id: SparrowAuth::Account::VERIFIED)
    account_for(address)
  end

  # RULE (a). An unverified claim is a string the provider passed along, not
  # evidence that anybody controls the mailbox.
  describe "when the provider does not vouch for the email" do
    it "creates no account" do
      provider_says(email: "newcomer@example.org", verified: false)

      expect { sign_in_with_provider }.not_to change(SparrowAuth::Account, :count)
    end

    it "signs nobody in" do
      provider_says(email: "newcomer@example.org", verified: false)
      sign_in_with_provider

      expect(account_for("newcomer@example.org")).to be_nil
    end

    it "treats a missing signal as unverified rather than as absent grounds to doubt" do
      OmniAuth.config.mock_auth[:developer] = OmniAuth::AuthHash.new(
        provider: "developer", uid: "u", info: {email: "newcomer@example.org"}
      )

      expect { sign_in_with_provider }.not_to change(SparrowAuth::Account, :count)
    end

    # That audit recorded seeing this as both a boolean and the string
    # "true", which is why it is cast rather than trusted.
    it "accepts the string \"true\" as the boolean it means" do
      provider_says(email: "newcomer@example.org", verified: "true")

      expect { sign_in_with_provider }.to change(SparrowAuth::Account, :count).by(1)
    end

    it "does not accept the string \"false\" as truthy" do
      provider_says(email: "newcomer@example.org", verified: "false")

      expect { sign_in_with_provider }.not_to change(SparrowAuth::Account, :count)
    end

    it "reads the signal when the provider only puts it under extra.raw_info" do
      provider_says(email: "newcomer@example.org", verified: true, raw: true)

      expect { sign_in_with_provider }.to change(SparrowAuth::Account, :count).by(1)
    end
  end

  # RULE (b). The bug behind this was `user.permissions = "admin"`, which made
  # every Google sign-in an administrator.
  describe "what an account created this way is given" do
    before { provider_says(email: "newcomer@example.org") }

    it "is created verified, because the provider vouched for the address" do
      sign_in_with_provider

      expect(account_for("newcomer@example.org")).to be_verified
    end

    # The property under test is that connecting a provider inherits NOTHING.
    #
    # This assertion has now been round the houses: it began as "belongs to no
    # organization", became "belongs only to one of its own" when a default
    # started handing them out, and is back where it started now that default is
    # gone. Worth saying plainly what it is actually for -- an address asserted
    # by Google is a claim, and a claim must not become a way into somewhere
    # that already exists.
    it "gets no way into anybody else's organization" do
      established = SparrowAuth::Organization.create!(name: "Established")

      sign_in_with_provider
      account = account_for("newcomer@example.org")

      expect(account.organizations.map(&:id)).not_to include(established.id)
      expect(account.memberships).to be_empty
    end

    # This asked that the new account held no Grant. Grants are gone with the
    # resolver they served, and the property that mattered survives in the
    # example above: connecting a provider inherits nothing. What is left to
    # say here is the membership side of it — a provider asserting an address
    # is not a way into an organization that address happens to be known in.
    it "is seated in nothing an existing organization already has" do
      established = SparrowAuth::Organization.create!(name: "Established")

      sign_in_with_provider
      account = account_for("newcomer@example.org")

      expect(established.memberships).to be_empty
      expect(account.membership_in(established)).to be_nil
    end

    it "has no password, so this creates no new way to guess in" do
      sign_in_with_provider
      account = account_for("newcomer@example.org")

      hashes = ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM sparrow_auth_account_password_hashes WHERE id = #{account.id.to_i}"
      )
      expect(hashes.to_i).to eq(0)
    end

    # Provisioning is the host's, reached identically by every sign-in method, which is
    # what leaves the engine with no place to grant anything.
    it "reaches the same provisioning hook as every other sign-in method" do
      seen = []
      SparrowAuth.config.after_first_signin = ->(account) { seen << account.email }

      sign_in_with_provider

      expect(seen).to eq(["newcomer@example.org"])
    end
  end

  # RULE (c), and the third audit finding: `where(email: ...).first_or_create`
  # signs the visitor into whatever account happens to share the address.
  describe "when the address already has an account that never connected this provider" do
    let!(:existing) { register_and_verify("owner@example.org") }

    before do
      post "/auth/logout"
      SparrowMail.deliveries.clear
      provider_says(email: "owner@example.org")
    end

    it "does not sign them in" do
      sign_in_with_provider

      expect(sessions_for(existing)).to eq(0)
    end

    it "connects nothing" do
      sign_in_with_provider

      expect(existing.identities).to be_empty
    end

    it "creates no second account for the address" do
      expect { sign_in_with_provider }.not_to change(SparrowAuth::Account, :count)
    end

    # Uniform on screen, truth in the mailbox — the same resolution used
    # everywhere else the engine refuses to say what happened.
    it "tells the address's owner, and says how to connect it deliberately" do
      sign_in_with_provider

      notice = SparrowMail.deliveries.last
      expect(notice.to.map(&:email)).to include("owner@example.org")
      expect(notice.text_body).to include(SparrowAuth.config.sign_in_path)
    end
  end

  describe "connecting a provider deliberately" do
    let!(:account) { register_and_verify("owner@example.org") }

    before do
      # Signed in first, deliberately: connecting is something an authenticated
      # person does, and the whole point of rule (c) is that arriving at the
      # callback without a session connects nothing.
      post "/auth/login", params: {login: "owner@example.org", password: password}
      provider_says(email: "owner@example.org")
    end

    it "attaches it to the account that asked, while they are signed in" do
      expect { sign_in_with_provider }.to change { account.identities.count }.by(1)
    end

    it "then signs that account in on a later visit" do
      sign_in_with_provider
      post "/auth/logout"

      expect { sign_in_with_provider }.to change { sessions_for(account) }.by(1)
    end

    # One provider account, one account here. Otherwise there is one identity,
    # two people who believe they own it, and a sign-in that lands wherever the
    # row happens to point.
    it "refuses to connect a provider account somebody else already connected" do
      sign_in_with_provider
      post "/auth/logout"

      other = register_and_verify("other@example.org")
      post "/auth/login", params: {login: "other@example.org", password: password}

      expect { sign_in_with_provider }.not_to change { other.identities.count }
    end
  end

  # The connections screen is the application's, written by the application's own page. What it stands on is here: the identity
  # rows, reached through `current_account.identities`, and the fact that taking
  # one away really does close that way in.
  describe "disconnecting" do
    let!(:account) { register_and_verify("owner@example.org") }

    before do
      post "/auth/login", params: {login: "owner@example.org", password: password}
      provider_says(email: "owner@example.org")
      sign_in_with_provider
    end

    it "lists what is connected" do
      listed = account.identities.oldest_first.to_a

      expect(listed.map(&:provider)).to eq(["developer"])
      expect(listed.first.display_name).to include("Developer")
    end

    it "removes the connection" do
      connection = account.identities.first

      expect { connection.destroy! }.to change { account.identities.count }.by(-1)
    end

    # A standing way in held by somebody else's system, so taking it away has
    # to actually take it away.
    it "stops that provider signing in afterwards" do
      account.identities.first.destroy!
      post "/auth/logout"

      expect { sign_in_with_provider }.not_to change { sessions_for(account) }
    end

    # The identity id is not a secret, so a lookup matching on it alone would
    # let anybody who saw one disconnect somebody else's provider. Reached
    # through the account's own association there is nothing to refuse: it is
    # not in the set.
    it "does not find a connection belonging to another account" do
      mine = account.identities.first
      other = register_and_verify("other@example.org")

      expect(other.identities.find_by(id: mine.id)).to be_nil
      expect(mine.reload).to be_present
    end

    it "refuses to show anything to a signed-out visitor" do
      post "/auth/logout"

      expect { get "/account-settings" }.to raise_error(SparrowAuth::UnverifiedAccount)
    end

    # Disconnecting everything is safe, which is what makes it offerable at all:
    # the emailed-code road in does not care whether a provider was ever
    # connected.
    it "leaves the emailed-code sign-in method working after the last one goes" do
      account.identities.first.destroy!
      post "/auth/logout"

      request_id = SparrowAuth::SignIn.request(
        email: "owner@example.org", ip: "203.0.113.31"
      )
      code = SparrowMail.deliveries.last.text_body[/\b\d{6}\b/]

      redeemed = SparrowAuth::SignIn.redeem(
        code: code, request_id: request_id, ip: "203.0.113.31"
      )

      expect(redeemed.id).to eq(account.id)
    end
  end

  describe "when a host has not asked for social sign-in" do
    it "is the default" do
      SparrowAuth.reset!

      expect(SparrowAuth.config.social_providers).to be_empty
      expect(SparrowAuth.config.social?).to be(false)
    end
  end
end
