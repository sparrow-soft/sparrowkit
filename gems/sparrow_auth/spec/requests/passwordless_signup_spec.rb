# frozen_string_literal: true

require "rails_helper"

# Creating an account with nothing but an emailed code.
#
# This is one earlier application's shape: one field, one code, and an account that never had a
# password to choose, reuse, forget or have breached somewhere else. The code
# proves control of the mailbox, which is the only thing the account ever had to
# prove — and it is the same proof the confirmation link asks for, obtained by a
# person typing six digits rather than by something following a URL.
#
# It used to be driven through POST /auth/otp. That screen is the application's
# now, so the flow is driven through SparrowAuth::SignIn, which is what the
# generated screen calls and where every decision below actually lives. The one
# example that still speaks HTTP does so because the race it describes needs
# Rodauth's own create-account route to run in the middle of it.
RSpec.describe "signing up with a code", type: :request do
  let(:ip) { "203.0.113.24" }

  def request_code(address)
    SparrowAuth::SignIn.request(email: address, ip: ip)
  end

  def last_code
    SparrowMail.deliveries.last.text_body[/\b\d{6}\b/]
  end

  def redeem(request_id, code = last_code)
    SparrowAuth::SignIn.redeem(code: code, request_id: request_id, ip: ip)
  end

  def password_hashes_for(account)
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_password_hashes " \
      "WHERE id = #{account.id.to_i}"
    ).to_i
  end

  def sessions_for(account)
    ActiveRecord::Base.connection.select_value(
      "SELECT count(*) FROM sparrow_auth_account_active_session_keys " \
      "WHERE account_id = #{account.id.to_i}"
    ).to_i
  end

  describe "a brand new address" do
    it "creates a verified account when the code is redeemed" do
      request_id = request_code("newcomer@example.org")

      expect { redeem(request_id) }.to change(SparrowAuth::Account, :count).by(1)

      account = SparrowAuth::Account.find_by_email("newcomer@example.org")
      expect(account).to be_verified
    end

    it "creates it with no password at all" do
      request_id = request_code("newcomer@example.org")
      redeem(request_id)

      account = SparrowAuth::Account.find_by_email("newcomer@example.org")
      expect(password_hashes_for(account)).to eq(0)
    end

    # An account arriving this way is verified, so an application that
    # provisions on verification must not care which road it came by.
    it "fires after_verification, as the confirmation link does" do
      seen = []
      SparrowAuth.config.after_verification = ->(account) { seen << account.email }

      request_id = request_code("newcomer@example.org")
      redeem(request_id)

      expect(seen).to eq(["newcomer@example.org"])
    end

    # Issuing a code is something anybody can trigger for any address. Redeeming
    # one is not. So nothing exists until the second step.
    it "creates nothing for a code that is never redeemed" do
      expect { request_code("newcomer@example.org") }
        .not_to change(SparrowAuth::Account, :count)
    end

    it "creates nothing for a wrong code" do
      request_id = request_code("newcomer@example.org")

      expect {
        begin
          redeem(request_id, "000000")
        rescue SparrowAuth::InvalidCode
          nil
        end
      }.not_to change(SparrowAuth::Account, :count)
    end
  end

  # The branch deliberately left alone. Somebody registered this address with a
  # password and never proved they could read the mailbox. Verifying it on the
  # strength of a code would hand the address's real owner an account whose
  # password a stranger chose.
  describe "an address registered with a password but never confirmed" do
    let!(:unconfirmed) do
      SparrowAuth::Account.create!(
        email: "unconfirmed@example.org",
        status_id: SparrowAuth::Account::UNVERIFIED
      )
    end

    it "gets no code" do
      request_code("unconfirmed@example.org")

      expect(SparrowAuth::OneTimeCode.where(email: "unconfirmed@example.org")).to be_empty
    end

    it "is told to confirm instead" do
      request_code("unconfirmed@example.org")

      expect(SparrowMail.deliveries.last.subject).to match(/confirm/i)
    end

    it "is not verified as a side effect" do
      request_code("unconfirmed@example.org")

      expect(unconfirmed.reload).not_to be_verified
      expect(sessions_for(unconfirmed)).to eq(0)
    end

    it "does not become a second account" do
      expect { request_code("unconfirmed@example.org") }
        .not_to change(SparrowAuth::Account, :count)
    end
  end

  # Addresses arrive as people type them, which is not how they are stored.
  describe "an address typed with odd case or stray spaces" do
    it "creates one account, in normalised form" do
      request_id = request_code("  Mixed.Case@Example.ORG  ")
      redeem(request_id)

      expect(SparrowAuth::Account.pluck(:email)).to eq(["mixed.case@example.org"])
    end

    # The send budget is keyed on the address, so the address it is keyed on
    # had better be the normalised one. Left raw, "Bob@example.org" and
    # "bob@example.org" are two buckets, and one send per minute becomes as
    # many as you can be bothered to type — to a mailbox whose owner never
    # asked for any of them.
    #
    # Nothing else in the engine notices: the account lookup normalises, the
    # code row normalises, and the column is citext, so every other assertion
    # passes while the limit quietly does not apply.
    # Counted in messages sent, not in code rows: issuing a code deletes any
    # earlier unconsumed one for the same address, so the row count cannot move
    # whether the limit held or not. The first version of this spec counted
    # rows and passed against a deliberately broken limiter.
    it "spends one send budget however the address is capitalised" do
      request_code("bob@example.org")
      sent = SparrowMail.deliveries.size

      request_code("BOB@Example.ORG")

      expect(SparrowMail.deliveries.size).to eq(sent),
        "a second message was sent within the per-address budget by changing case"
    end

    # The failure this prevents is two accounts for one person, each holding
    # half their data, neither obviously wrong.
    it "signs into the same account when typed differently the next time" do
      redeem(request_code("Mixed.Case@Example.ORG"))
      SparrowAuth::AuthEvent.delete_all

      request_id = request_code("mixed.case@example.org")

      expect { redeem(request_id) }.not_to change(SparrowAuth::Account, :count)
    end
  end

  # The whole reason the engine exists in this shape: an invitation is a grant,
  # and it must land with the person who can read the mailbox. An account made
  # by code is verified, so it can accept — and this is the path a new invitee
  # will actually take now that there is no password to choose.
  describe "accepting an invitation as a code-created account" do
    it "lets the invitee accept" do
      inviter = SparrowAuth::Account.create!(
        email: "inviter@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      _invitation, token = SparrowAuth::Invitation.invite!(
        email: "invitee@example.org", invited_by: inviter,
        url_builder: ->(t) { "http://example.com/auth/invitations/#{t}" }
      )

      account = redeem(request_code("invitee@example.org"))

      expect { SparrowAuth::Invitation.redeem!(token: token, account: account) }
        .not_to raise_error
    end

    # The registration-hijack pattern this engine was built to close, checked
    # again on the new road in: an account that took the password route and
    # never confirmed still cannot accept, however the invitation reached it.
    it "still refuses an account that never confirmed" do
      inviter = SparrowAuth::Account.create!(
        email: "inviter@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
      _invitation, token = SparrowAuth::Invitation.invite!(
        email: "invitee@example.org", invited_by: inviter,
        url_builder: ->(t) { "http://example.com/auth/invitations/#{t}" }
      )
      impostor = SparrowAuth::Account.create!(
        email: "invitee@example.org", status_id: SparrowAuth::Account::UNVERIFIED
      )

      expect { SparrowAuth::Invitation.redeem!(token: token, account: impostor) }
        .to raise_error(SparrowAuth::AccessError)
    end
  end

  # The race that makes the guard in #redeem reachable, and the reason it is
  # written as a refusal rather than as a repair.
  #
  # A code is issued for an address with no account. Before it is redeemed,
  # somebody registers that same address with a password and never confirms it.
  # Redeeming the code now finds an unverified account — and verifying it would
  # sign the address's real owner into an account whose password a stranger
  # chose, having proved nothing.
  describe "when the address is claimed with a password between issue and redemption" do
    it "refuses the code rather than verifying somebody else's account" do
      request_id = request_code("contested@example.org")
      code = last_code

      # Rodauth's own route, still served by the middleware, and the only part
      # of this story that needs HTTP: the attacker is registering normally.
      post "/auth/create-account", params: {
        login: "contested@example.org",
        password: "the attacker's password",
        "password-confirm": "the attacker's password"
      }
      claimed = SparrowAuth::Account.find_by_email("contested@example.org")
      expect(claimed).not_to be_verified

      expect { redeem(request_id, code) }.to raise_error(SparrowAuth::InvalidCode)

      expect(claimed.reload).not_to be_verified
      expect(sessions_for(claimed)).to eq(0)
    end
  end

  # Reachable when the flag is turned off between issuing a code and redeeming
  # it, which is exactly when a guard that only sat on the issuing side would
  # have let one through.
  describe "when signup by code is switched off after a code was issued" do
    it "refuses to create the account" do
      request_id = request_code("newcomer@example.org")
      code = last_code

      SparrowAuth.config.signup_with_code = false

      expect {
        begin
          redeem(request_id, code)
        rescue SparrowAuth::InvalidCode
          nil
        end
      }.not_to change(SparrowAuth::Account, :count)
    end
  end

  describe "an address that already has a verified account" do
    let!(:existing) do
      SparrowAuth::Account.create!(
        email: "returning@example.org", status_id: SparrowAuth::Account::VERIFIED
      )
    end

    it "signs in rather than creating a second account" do
      request_id = request_code("returning@example.org")

      expect { redeem(request_id) }.not_to change(SparrowAuth::Account, :count)
    end

    it "hands back the account that already existed" do
      request_id = request_code("returning@example.org")

      expect(redeem(request_id).id).to eq(existing.id)
    end
  end
end
