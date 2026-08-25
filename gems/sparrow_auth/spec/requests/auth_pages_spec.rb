# frozen_string_literal: true

require "rails_helper"
require "uri"

# What Rodauth's own pages actually look like to somebody using them.
#
# These are the only pages left. SparrowKit ships no end-user pages, and the
# engine's hand-written passkey-setup template and its four layouts went with
# them — Rodauth's own defaults render now, through the host application's
# `application` layout, and `bin/rails generate rodauth:views` copies them into
# an application's app to own and restyle.
#
# So what this file used to assert about the engine's own markup is gone with
# the markup. What stays is the part that is still ours: the ceremony's fields
# have to be on the page for the browser to do anything at all, and the links
# the login page offers must not depend on who is asking.
RSpec.describe "the auth pages as rendered", type: :request do
  let(:password) { "correct horse battery staple" }

  def register_and_sign_in(address = "newcomer@example.org")
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
  end

  describe "the passkey setup page" do
    before { register_and_sign_in }

    # The ceremony is the one part of this an application cannot hand-roll, so the
    # fields it needs have to survive whatever anybody does to the page.
    it "carries everything the ceremony needs" do
      get "/auth/webauthn-setup"

      expect(response.body).to include("webauthn_setup_challenge")
      expect(response.body).to include("webauthn_setup_challenge_hmac")
      expect(response.body).to include('name="webauthn_setup"')
      expect(response.body).to include("webauthn-setup-js")
    end
  end

  describe "the sign-in page" do
    # The specific defect that reached a person: a second submit button,
    # offering a ceremony the script performs for you. Rodauth marks its
    # internal fields with Bootstrap's `d-none`, and this engine ships no
    # Bootstrap, so anything relying on that class is visible unless a layout
    # hides it — which is now the application's layout, and their problem to solve,
    # but the count of buttons Rodauth itself renders is still ours.
    it "leaves only one visible submit button" do
      get "/auth/login"

      visible = response.body.scan(/<input type="submit"[^>]*>/)
        .reject { |tag| tag.include?("d-none") }

      expect(visible.size).to eq(1), "sign-in shows #{visible.size} buttons: #{visible.inspect}"
    end

    # An account created by code has no password. Without this link the page
    # asks for something it does not have and offers no way onward -- and since
    # the emailed-code screen became the application's, the link has to follow
    # wherever they put it rather than name a page this engine serves.
    it "offers the emailed-code flow" do
      get "/auth/login"

      expect(response.body).to include(SparrowAuth.config.sign_in_path)
      expect(response.body).to match(/code instead/i)
    end

    # Which links appear must not depend on who is asking.
    it "offers it whether or not the submitted address exists" do
      register_and_sign_in("known@example.org")
      post "/auth/logout"

      post "/auth/login", params: {login: "known@example.org", password: "wrong"}
      for_known = response.body.include?(SparrowAuth.config.sign_in_path)

      post "/auth/login", params: {login: "stranger@example.org", password: "wrong"}

      expect(response.body.include?(SparrowAuth.config.sign_in_path)).to eq(for_known)
    end
  end
end
