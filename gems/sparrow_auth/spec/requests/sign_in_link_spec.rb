# frozen_string_literal: true

require "rails_helper"

# Signing in with a link, which is the other shape emailed sign-in comes in.
#
# The half worth testing hardest is not "does the link work". It is that
# choosing links does not quietly undo anything the code path had already got
# right: the same uniform answer to every address, the same rate limit, the same
# refusal to create an account for somebody who merely typed an address.
#
# Rodauth owns redeeming. Its route is GET, then session, then POST — opening
# the link stores the key and redirects, and the key is spent only when the page
# is submitted. That is what makes a mail scanner harmless, and it is tested
# here rather than assumed, because it is the entire argument for offering links
# at all.
RSpec.describe "signing in with a link", type: :request do
  before { SparrowAuth.config.emailed_sign_in = :link }

  def verified(email)
    SparrowAuth::Account.create!(email: email, status_id: SparrowAuth::Account::VERIFIED)
  end

  def ask_for_a_link(address)
    SparrowAuth::SignIn.request(
      email: address, ip: "127.0.0.1", base_url: "http://www.example.com"
    )
  end

  def link_in_the_last_message
    SparrowMail.deliveries.last.text_body[%r{https?://\S+}]
  end

  describe "asking for one" do
    it "sends a link to a verified account" do
      account = verified("owner@example.org")

      expect { ask_for_a_link(account.email) }.to change { SparrowMail.deliveries.size }.by(1)
      expect(link_in_the_last_message).to include("/auth/email-auth")
    end

    it "puts the key in the link and nothing else" do
      ask_for_a_link(verified("owner@example.org").email)

      expect(link_in_the_last_message).to match(/\?key=/)
    end

    # The host cannot be derived inside an internal request — Rodauth says so
    # outright — so it comes from the request the caller is already inside.
    # Without this the link has no host in it, which is not a link.
    it "builds the link against the address the request came in on" do
      ask_for_a_link(verified("owner@example.org").email)

      expect(link_in_the_last_message).to start_with("http://www.example.com/")
    end

    it "keeps the code out of the subject line, and the link too" do
      ask_for_a_link(verified("owner@example.org").email)

      expect(SparrowMail.deliveries.last.subject).not_to include("http")
    end

    # One live link per account. Asking again re-sends the same key rather than
    # issuing a second, so somebody who presses the button twice has one working
    # link and not two.
    it "re-sends the same link rather than issuing a second" do
      account = verified("owner@example.org")

      ask_for_a_link(account.email)
      first = link_in_the_last_message

      SparrowAuth::AuthEvent.delete_all
      ask_for_a_link(account.email)

      expect(link_in_the_last_message).to eq(first)
    end
  end

  describe "the answer on screen, which must not depend on who is asking" do
    it "hands back an opaque id for an address with no account" do
      expect(ask_for_a_link("nobody@example.org")).to match(/\A[0-9a-f]{64}\z/)
    end

    it "hands back one of the same shape for an address that has one" do
      known = ask_for_a_link(verified("owner@example.org").email)

      expect(known).to match(/\A[0-9a-f]{64}\z/)
    end

    it "sends no link to an address with no account" do
      ask_for_a_link("nobody@example.org")

      expect(SparrowMail.deliveries.last.text_body).not_to include("/auth/email-auth")
    end

    # The whole reason the request half stayed ours. Rodauth's own
    # email_auth_request route answers an address it does not recognise with a
    # different flash from one it does, which would have made exactly one of the
    # two mechanisms an enumeration oracle.
    it "spends the same rate-limit budget as a code does" do
      SparrowAuth.config.emailed_sign_in = :code
      ask_for_a_link(verified("owner@example.org").email)

      SparrowAuth.config.emailed_sign_in = :link

      expect { ask_for_a_link("owner@example.org") }.not_to change { SparrowMail.deliveries.size }
    end
  end

  # A link hangs on an account row, so the account has to exist before the mail
  # goes out. Creating one on request would let anybody make an account for any
  # address by typing it into a form, which is the surface the code path avoids
  # by creating the account on REDEMPTION instead.
  describe "an address nobody has yet" do
    around do |example|
      was = SparrowAuth.config.signup_with_code
      SparrowAuth.config.signup_with_code = true
      example.run
      SparrowAuth.config.signup_with_code = was
    end

    it "creates no account, even with signup turned on" do
      expect { ask_for_a_link("stranger@example.org") }.not_to change(SparrowAuth::Account, :count)
    end

    it "tells them by email that they have no account, rather than on screen" do
      ask_for_a_link("stranger@example.org")

      expect(SparrowMail.deliveries.last.to.map(&:email)).to eq(["stranger@example.org"])
      expect(SparrowMail.deliveries.last.text_body).not_to include("/auth/email-auth")
    end
  end

  describe "opening one" do
    let(:account) { verified("owner@example.org") }
    let(:link) do
      ask_for_a_link(account.email)
      link_in_the_last_message
    end

    # The property the whole mechanism rests on. A scanner that follows the link
    # gets a cookie and a page; it does not sign in, and the key survives for
    # the person the mail was for.
    it "does not sign anybody in on the GET" do
      get link

      follow_redirect!
      expect(account.sessions.count).to eq(0)
    end

    it "leaves the link still working after something has prefetched it" do
      get link
      reset!

      get link
      follow_redirect!
      post "/auth/email-auth"

      expect(account.sessions.count).to eq(1)
    end

    it "signs somebody in when the page is submitted" do
      get link
      follow_redirect!
      post "/auth/email-auth"

      expect(account.sessions.count).to eq(1)
    end

    # The key is stored in the session of the browser that opened the link, so
    # another browser holding the same URL has nothing. That is the cost of the
    # property above, and the honest reason the code flow still exists.
    it "cannot be finished in a different browser" do
      get link

      reset!
      post "/auth/email-auth"

      expect(account.sessions.count).to eq(0)
    end

    it "refuses a key that was never issued" do
      get "/auth/email-auth?key=#{account.id}_notakey"
      follow_redirect!
      post "/auth/email-auth"

      expect(account.sessions.count).to eq(0)
    end
  end

  # The setting is read on every call rather than when the Rodauth class was
  # configured, so an application that sets it after boot still gets what it
  # asked for.
  #
  # It was read at configuration time for an afternoon, and the symptom was the
  # worst kind: the setting changed, nothing raised, and the application went on
  # sending exactly what it had sent before. The Rodauth feature is enabled
  # either way now; what changes is only what SignIn sends.
  describe "when the application sends codes instead" do
    before { SparrowAuth.config.emailed_sign_in = :code }

    it "sends a code on the very next call" do
      ask_for_a_link(verified("owner@example.org").email)

      expect(SparrowMail.deliveries.last.text_body).to match(/\b\d{6}\b/)
      expect(SparrowMail.deliveries.last.text_body).not_to include("/auth/email-auth")
    end

    it "goes back to links just as immediately" do
      ask_for_a_link(verified("owner@example.org").email)
      SparrowAuth::AuthEvent.delete_all

      SparrowAuth.config.emailed_sign_in = :link
      ask_for_a_link("owner@example.org")

      expect(link_in_the_last_message).to include("/auth/email-auth")
    end
  end
end
