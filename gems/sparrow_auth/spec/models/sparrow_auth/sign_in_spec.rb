# frozen_string_literal: true

require "rails_helper"

# Signing in with an emailed code, written from the attacker's side.
#
# This used to be spec/requests/otp_sign_in_spec.rb, driving POST /auth/otp
# against a controller in the engine. That controller is gone: SparrowKit ships
# no end-user pages, and the sign-in screen is written into the application by
# `rails generate sparrowkit:screens sign_in`.
#
# What did NOT move is the part that matters. Almost none of signing in is about
# signing in — it is about not answering a question nobody asked, namely whether
# an address has an account — and every one of those decisions is in
# SparrowAuth::SignIn, in the engine, precisely so that a buyer cannot get it
# wrong by writing a page. So these assertions follow the property to where the
# property lives, and are asked of the service directly.
#
# The screen's own half — the cookie's attributes, the one sentence on screen —
# is asserted against what the generator writes, in
# spec/generators/screens_generator_spec.rb.
RSpec.describe SparrowAuth::SignIn do
  let(:email) { "person@example.org" }
  let(:ip) { "203.0.113.10" }
  let(:base_url) { "http://www.example.com" }

  def verified_account(address = email)
    SparrowAuth::Account.create!(address_and_status(address, SparrowAuth::Account::VERIFIED))
  end

  def unverified_account(address)
    SparrowAuth::Account.create!(address_and_status(address, SparrowAuth::Account::UNVERIFIED))
  end

  def address_and_status(address, status)
    {email: address, status_id: status}
  end

  def request_code(address = email, from: ip)
    described_class.request(email: address, ip: from, base_url: base_url)
  end

  def last_code
    SparrowMail.deliveries.last.text_body[/\b(\d{6})\b/, 1]
  end

  # Everything an observer of the return value can see. The whole anti-
  # enumeration claim is that this tuple is the same in every branch, so the
  # comparisons below are made on it rather than on the id itself — two ids that
  # were equal would mean something far worse than an oracle.
  def observable(request_id)
    [request_id.class, request_id.to_s.length, request_id.to_s.match?(/\A[0-9a-f]+\z/)]
  end

  describe "requesting a code" do
    before { verified_account }

    it "sends one" do
      expect { request_code }.to change { SparrowMail.deliveries.size }.by(1)

      expect(SparrowMail.deliveries.last.to.first.email).to eq(email)
    end

    it "keeps the code out of the subject" do
      request_code

      expect(SparrowMail.deliveries.last.subject).to eq("Your sign-in code")
      expect(SparrowMail.deliveries.last.subject).not_to match(/\d{6}/)
    end

    it "rides the transactional stream" do
      request_code

      expect(SparrowMail.deliveries.last.stream).to eq(:transactional)
    end
  end

  # The heart of it. Whether an address has an account is not a question this
  # answers, by return value, by exception, or by what it sends.
  describe "anti-enumeration" do
    it "answers an unknown address exactly as it answers a known one" do
      verified_account
      known = request_code

      unknown = request_code("nobody-here@example.org")

      expect(observable(unknown)).to eq(observable(known))
    end

    # The id is opaque, so it must also not BE the same id: an id a caller could
    # recognise across requests would identify the branch just as well as a
    # different shape would.
    it "answers with a fresh id each time, so the id itself names nothing" do
      verified_account

      expect(request_code).not_to eq(request_code("nobody-here@example.org"))
    end

    it "answers a rate-limited address exactly the same way" do
      verified_account
      known = request_code

      limited = request_code

      expect(observable(limited)).to eq(observable(known))
    end

    # The bug this is written against was live for about an hour: request_code
    # returned nil when over budget, and any caller branching on nil — a
    # different flash, a 429 — turns the rate limiter into the oracle the rest
    # of the file exists to prevent.
    it "never answers with nothing, however far over budget the caller is" do
      verified_account

      6.times { expect(request_code).to be_a(String) }
    end

    it "sends nothing for the rate-limited request, whatever it answered" do
      verified_account
      request_code

      expect { request_code }.not_to change { SparrowMail.deliveries.size }
    end

    # A provider outage must not become an oracle, and it is the case most
    # likely to be missed because it only shows up when something else is wrong.
    it "answers the same way when the email cannot be sent at all" do
      verified_account
      healthy = request_code

      SparrowMail::Adapters::Test.fail_with(SparrowMail::ProviderError)
      failed = request_code("someone.else@example.org")

      expect(observable(failed)).to eq(observable(healthy))
    ensure
      SparrowMail::Adapters::Test.stop_failing
    end

    it "logs a send failure without the code in it" do
      verified_account
      SparrowMail::Adapters::Test.fail_with(SparrowMail::ProviderError)
      log = StringIO.new
      original = Rails.logger
      Rails.logger = ActiveSupport::Logger.new(log)

      request_code

      expect(log.string).to include("otp_send_failed")
      expect(log.string).not_to match(/\b\d{6}\b/)
    ensure
      Rails.logger = original
      SparrowMail::Adapters::Test.stop_failing
    end

    # A caller cannot branch on an exception it never sees. Every branch returns;
    # none of them raises, including the ones that sent nothing.
    it "never raises, whatever the address turns out to be" do
      verified_account

      ["", "   ", "nobody@example.org", email, "not-an-address"].each do |address|
        expect { request_code(address) }.not_to raise_error
      end
    end
  end

  # The resolution of the tension between not leaking who has an account and not
  # stranding people who do: the answer is identical in every case, and the
  # explanation goes to the mailbox, which is the one channel that proves who
  # owns the address.
  describe "telling the truth to the mailbox instead of the screen" do
    it "answers identically for verified, unverified and unknown addresses" do
      verified_account("verified@example.org")
      unverified_account("unconfirmed@example.org")

      answers = ["verified@example.org", "unconfirmed@example.org", "nobody@example.org"]
        .map { |address| observable(request_code(address)) }

      expect(answers.uniq.size).to eq(1)
    end

    # The screen sets its cookie from this return value and sets it
    # unconditionally, so "an id in every branch" is what makes the cookie's
    # presence unable to tell the branches apart. There is no branch here in
    # which a caller has nothing to set.
    it "returns an id in every case, so the cookie it sets cannot tell them apart" do
      verified_account("verified@example.org")
      unverified_account("unconfirmed@example.org")

      ["verified@example.org", "unconfirmed@example.org", "nobody@example.org"].each do |address|
        expect(request_code(address)).to be_present, "no request id for #{address}"
      end
    end

    it "sends a code to a verified address" do
      verified_account
      request_code

      expect(SparrowMail.deliveries.last.subject).to eq("Your sign-in code")
    end

    # The case that would otherwise strand a real person: registered, never
    # clicked the link, and now told their code is invalid with no way to work
    # out why.
    it "sends the way to confirm, to an address that never confirmed" do
      unverified_account("unconfirmed@example.org")

      request_code("unconfirmed@example.org")

      expect(SparrowMail.deliveries.last.subject).to eq("Confirm your email address to sign in")
      expect(SparrowMail.deliveries.last.text_body).to include("verify-account-resend")
    end

    it "issues no code to an address that never confirmed" do
      unverified_account("unconfirmed@example.org")

      request_code("unconfirmed@example.org")

      expect(SparrowAuth::OneTimeCode.where(email: "unconfirmed@example.org")).to be_empty
    end

    # The default now: an address with no account gets a real code, because that
    # code is how an account is made. Nothing is created until it is redeemed —
    # anybody can trigger a send for any address, and only the person reading
    # the mailbox can redeem one.
    it "emails a code to an address with no account" do
      request_code("nobody@example.org")

      expect(SparrowMail.deliveries.last.text_body).to match(/\b\d{6}\b/)
      expect(SparrowAuth::OneTimeCode.where(email: "nobody@example.org")).not_to be_empty
    end

    it "creates nothing until the code is actually redeemed" do
      expect { request_code("nobody@example.org") }
        .not_to change(SparrowAuth::Account, :count)
    end

    describe "with signup by code switched off" do
      before { SparrowAuth.config.signup_with_code = false }

      it "tells an address with no account that there is none, rather than emailing a code" do
        request_code("nobody@example.org")

        expect(SparrowMail.deliveries.last.subject).to eq("Someone asked to sign in with your address")
        expect(SparrowMail.deliveries.last.text_body).not_to match(/\b\d{6}\b/)
      end

      it "issues no code for an address with no account" do
        request_code("nobody@example.org")

        expect(SparrowAuth::OneTimeCode.count).to be_zero
      end

      it "still answers the same way as it does for an address that has one" do
        verified_account
        known = request_code

        unknown = request_code("nobody@example.org")

        expect(observable(unknown)).to eq(observable(known))
      end
    end
  end

  describe "redeeming" do
    before { verified_account }

    it "returns the account for the right code" do
      request_id = request_code

      account = described_class.redeem(code: last_code, request_id: request_id, ip: ip)

      expect(account.email).to eq(email)
    end

    it "refuses a wrong code" do
      request_id = request_code

      expect { described_class.redeem(code: "000000", request_id: request_id, ip: ip) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    # The code alone is not enough. Without the request id — which the screen
    # keeps in an encrypted, host-only cookie — it is a six-digit secret anyone
    # could try, and six digits is a million guesses against a rate limit rather
    # than against nothing.
    it "refuses the right code presented under a request id that never asked for it" do
      request_code
      code = last_code

      expect {
        described_class.redeem(code: code, request_id: SecureRandom.hex(32), ip: ip)
      }.to raise_error(SparrowAuth::InvalidCode)
    end

    it "refuses the right code with no request id at all" do
      request_code
      code = last_code

      expect { described_class.redeem(code: code, request_id: nil, ip: ip) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    # Sharper than the version this replaces, which unverified the account
    # before asking for a code and so never issued one to refuse. Here the code
    # is genuinely valid and the account's standing is what refuses it, which is
    # the line in #redeem that exists for the registration-hijack case.
    it "refuses an account that has stopped being verified, even with the right code" do
      request_id = request_code
      code = last_code
      SparrowAuth::Account.find_by_email(email)
        .update!(status_id: SparrowAuth::Account::UNVERIFIED)

      expect { described_class.redeem(code: code, request_id: request_id, ip: ip) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    it "cannot be replayed" do
      request_id = request_code
      code = last_code
      described_class.redeem(code: code, request_id: request_id, ip: ip)

      expect { described_class.redeem(code: code, request_id: request_id, ip: ip) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    # Every refusal is one error with one message. Telling somebody which wall
    # they hit tells them whether to keep going.
    it "answers a wrong code exactly as it answers an expired one" do
      request_id = request_code
      wrong = refusal_from { described_class.redeem(code: "000000", request_id: request_id, ip: ip) }

      second_id = request_code("someone.else@example.org")
      code = last_code
      SparrowAuth::OneTimeCode.last.update!(expires_at: 1.second.ago)
      expired = refusal_from { described_class.redeem(code: code, request_id: second_id, ip: ip) }

      expect(expired).to eq(wrong)
    end

    it "answers a code past the attempt cap exactly the same way too" do
      request_id = request_code
      wrong = refusal_from { described_class.redeem(code: "000000", request_id: request_id, ip: ip) }

      capped = nil
      SparrowAuth::OneTimeCode::MAX_ATTEMPTS.times do
        capped = refusal_from { described_class.redeem(code: "000000", request_id: request_id, ip: ip) }
      end

      expect(capped).to eq(wrong)
    end

    it "refuses everything once the verify budget is spent, without saying so" do
      request_id = request_code
      code = last_code
      SparrowAuth::RateLimiter::VERIFY_PER_IP.limit.times do
        refusal_from { described_class.redeem(code: "000000", request_id: request_id, ip: ip) }
      end

      expect { described_class.redeem(code: code, request_id: request_id, ip: ip) }
        .to raise_error(SparrowAuth::InvalidCode, "That code is not valid")
    end

    def refusal_from
      yield
      raise "expected a refusal and got none"
    rescue SparrowAuth::AccessError => e
      [e.class, e.message]
    end
  end

  describe "budget independence" do
    # The bug that made one earlier application's venue WiFi unusable: verify attempts were
    # counted against the send budget, so a room of people signing in locked
    # each other out and nothing in the logs said why.
    it "does not let verify attempts consume the send budget" do
      verified_account
      request_id = request_code
      SparrowAuth::AuthEvent.where(bucket: "otp_send:email").update_all(created_at: 2.minutes.ago)

      10.times do
        described_class.redeem(code: "000000", request_id: request_id, ip: ip)
      rescue SparrowAuth::InvalidCode
        nil
      end

      expect { request_code }.to change { SparrowMail.deliveries.size }.by(1)
    end

    # The other half of the same claim, and the one that keeps a shared office
    # from locking itself out: one address over its budget must not spend
    # anybody else's.
    it "does not let one address spend another address's send budget" do
      verified_account
      verified_account("colleague@example.org")
      2.times { request_code }

      expect { request_code("colleague@example.org") }
        .to change { SparrowMail.deliveries.size }.by(1)
    end
  end
end
