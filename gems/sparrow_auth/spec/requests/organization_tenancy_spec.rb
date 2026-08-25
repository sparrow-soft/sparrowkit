# frozen_string_literal: true

require "rails_helper"
require "uri"

# Tenancy over real HTTP, through a host application's own controller.
#
# The model specs prove the scope holds when Current.organization is set. What
# this proves is that it gets set from the right place, re-checked often enough,
# and that a request from a signed-in person for somebody else's tenant is
# refused rather than served.
RSpec.describe "tenancy over HTTP", type: :request do
  let(:password) { "correct horse battery staple" }

  # Every example here builds the membership shape it is about — one
  # organization, two, none — so the personal organization a new account
  # normally gets would be an extra membership none of them asked for. Switched
  # off rather than worked around, because "exactly one membership" is the
  # thing several of these examples are testing.
  before { SparrowAuth.config.after_first_signin = nil }

  def register(address)
    post "/auth/create-account", params: {
      login: address, password: password, "password-confirm": password
    }
    url = SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
    key = URI.decode_www_form(URI.parse(url).query.to_s).to_h["key"]
    get url
    # GET first, the way somebody clicking the emailed link does. Rodauth 2.47
    # takes the key from the session that GET establishes rather than from the
    # POST body, so a POST on its own is refused -- and a POST on its own is not
    # a thing a browser ever does.
    get "/auth/verify-account", params: {key: key}
    post "/auth/verify-account", params: {key: key}
    post "/auth/logout"

    SparrowAuth::Account.find_by_email(address)
  end

  def sign_in(address)
    post "/auth/login", params: {login: address, password: password}
  end

  # A second organization that somebody else already owns, with `account` seated
  # in it at `role`. Roles are assigned by somebody now: there is no path that
  # creates one without naming who did it, so every organization here has an
  # owner from the moment it exists.
  def organization_seating(account, role, name:)
    host = SparrowAuth::Account.create!(
      email: "host-of-#{name.parameterize}@example.org",
      status_id: SparrowAuth::Account::VERIFIED
    )
    organization = SparrowAuth::Organization.create_with_owner!(account: host, name: name)
    organization.memberships.create!(account: account, role: role)
    organization
  end

  describe "resolving the current organization" do
    it "uses the account's only membership when it has exactly one" do
      account = register("solo@example.org")
      organization = SparrowAuth::Organization.create_with_owner!(account: account, name: "Acme")
      sign_in("solo@example.org")

      get "/widgets/whoami"

      expect(response.body).to eq(organization.slug)
    end

    # Choosing on somebody's behalf is how a person writes into the wrong tenant
    # while believing they were somewhere else.
    it "picks none when the account belongs to several" do
      account = register("consultant@example.org")
      SparrowAuth::Organization.create_with_owner!(account: account, name: "First")
      organization_seating(account, :member, name: "Second")
      sign_in("consultant@example.org")

      get "/widgets/whoami"

      expect(response.body).to eq("")
    end

    it "uses the chosen organization once one is switched to" do
      account = register("consultant@example.org")
      first = SparrowAuth::Organization.create_with_owner!(account: account, name: "First")
      second = organization_seating(account, :member, name: "Second")
      sign_in("consultant@example.org")

      post "/widgets/switch", params: {organization_id: second.id}
      expect(response.body).to eq(second.slug)

      get "/widgets/whoami"
      expect(response.body).to eq(second.slug)
      expect(first.slug).not_to eq(second.slug)
    end
  end

  describe "a request for an organization the account does not belong to" do
    it "refuses to switch into it" do
      register("outsider@example.org")
      someone_elses = SparrowAuth::Organization.create!(name: "Not Theirs")
      sign_in("outsider@example.org")

      post "/widgets/switch", params: {organization_id: someone_elses.id}

      expect(response).to have_http_status(:forbidden)
    end

    # The session holds a record of what somebody chose, not evidence they may
    # still have it. If this were trusted from the session alone, revoking
    # access would leave them inside the tenant until they happened to sign out.
    it "drops them out of a tenant as soon as the membership is revoked" do
      account = register("departing@example.org")
      organization = SparrowAuth::Organization.create_with_owner!(account: account, name: "Acme")
      second_owner = SparrowAuth::Account.create!(
        email: "remaining@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      organization.memberships.create!(account: second_owner, role: :owner)
      sign_in("departing@example.org")

      post "/widgets/switch", params: {organization_id: organization.id}
      expect(response.body).to eq(organization.slug)

      organization.memberships.find_by(account: account).destroy!

      get "/widgets/whoami"
      expect(response.body).to eq("")
    end
  end

  describe "scoped reads and writes" do
    it "shows only the current organization's rows" do
      account = register("solo@example.org")
      mine = SparrowAuth::Organization.create_with_owner!(account: account, name: "Mine")
      theirs = SparrowAuth::Organization.create!(name: "Theirs")
      SparrowAuth.across_all_organizations(reason: "spec setup") do
        Widget.create!(name: "ours", organization: mine)
        Widget.create!(name: "not ours", organization: theirs)
      end
      sign_in("solo@example.org")

      get "/widgets"

      expect(response.body).to eq("ours")
    end

    it "stamps a created row with the current organization" do
      account = register("solo@example.org")
      organization = SparrowAuth::Organization.create_with_owner!(account: account, name: "Acme")
      sign_in("solo@example.org")

      post "/widgets", params: {name: "fresh"}

      expect(response.body).to eq(organization.id.to_s)
    end

    # A signed-in person with no tenant resolved must not get everybody's rows.
    it "refuses a scoped read when no organization is resolved" do
      register("consultant@example.org")
      account = SparrowAuth::Account.find_by_email("consultant@example.org")
      SparrowAuth::Organization.create_with_owner!(account: account, name: "First")
      organization_seating(account, :member, name: "Second")
      sign_in("consultant@example.org")

      get "/widgets"

      expect(response).to have_http_status(:forbidden)
    end
  end
end
