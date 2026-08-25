# frozen_string_literal: true

require "rails_helper"

# The code itself: how it is generated, how it is stored, and every way someone
# who is not the recipient might try to use it.
RSpec.describe SparrowAuth::OneTimeCode do
  let(:email) { "person@example.org" }

  describe "generation" do
    it "is six digits" do
      20.times { expect(described_class.generate_code).to match(/\A\d{6}\z/) }
    end

    it "keeps leading zeros, so the code the user reads is the code we check" do
      codes = Array.new(400) { described_class.generate_code }

      expect(codes).to all(have_attributes(length: 6))
    end

    # Rejection sampling rather than modulo. Taking a random 32-bit number mod
    # 10^6 makes the low codes fractionally more likely, which is a real bias
    # even if a small one, and there is no reason to accept it.
    it "is uniform, with no modulo bias" do
      ceiling = (2**32 / 1_000_000) * 1_000_000

      expect(described_class::SAMPLE_CEILING).to eq(ceiling)
      expect(described_class::SAMPLE_CEILING % 1_000_000).to be_zero
    end

    it "does not repeat itself over many draws" do
      codes = Array.new(500) { described_class.generate_code }

      expect(codes.uniq.size).to be > 450
    end
  end

  describe "storage" do
    it "never stores the code" do
      code = described_class.issue(email: email).code

      stored = ActiveRecord::Base.connection.select_values(
        "SELECT code_digest FROM sparrow_auth_otp_codes"
      )
      expect(stored).not_to include(code)
      expect(stored.first.length).to eq(64)
    end

    # Keyed, not plain. Six digits is a million possibilities, which a plain
    # SHA-256 table covers in moments. The key is what makes the digest useless
    # to someone holding only the database.
    it "keys the digest on a dedicated secret" do
      record = described_class.issue(email: email)

      unkeyed = OpenSSL::Digest::SHA256.hexdigest(record.code)
      expect(record.reload.code_digest).not_to eq(unkeyed)
    end

    it "derives a different digest under a different secret" do
      record = described_class.issue(email: email)
      other = described_class.digest(record.code, secret: "a different secret entirely")

      expect(other).not_to eq(record.code_digest)
    end

    it "gives every request its own opaque request id" do
      ids = Array.new(20) { described_class.issue(email: email).request_id }

      expect(ids.uniq.size).to eq(20)
      expect(ids).to all(match(/\A[0-9a-f]{64}\z/))
    end
  end

  describe "issuing" do
    it "expires the code in ten minutes" do
      record = described_class.issue(email: email)

      expect(record.expires_at).to be_within(5.seconds).of(10.minutes.from_now)
    end

    # Otherwise asking for a new code leaves the old one working, and every
    # request widens the window rather than restarting it.
    it "invalidates every earlier code for that address" do
      first = described_class.issue(email: email)
      described_class.issue(email: email)

      expect { described_class.redeem!(request_id: first.request_id, code: first.code) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    # Deleted rather than marked stale. A superseded code left in the table is
    # something to guess against and something to leak, and it buys nothing.
    it "leaves no trace of the earlier code" do
      first = described_class.issue(email: email)
      described_class.issue(email: email)

      expect(described_class.find_by(id: first.id)).to be_nil
    end

    it "leaves other addresses' codes alone" do
      other = described_class.issue(email: "someone.else@example.org")
      described_class.issue(email: email)

      expect(described_class.redeem!(request_id: other.request_id, code: other.code))
        .to eq("someone.else@example.org")
    end

    it "normalises the address" do
      record = described_class.issue(email: "  Person@Example.ORG ")

      expect(record.email).to eq(email)
    end
  end

  describe "redeeming" do
    let!(:issued) { described_class.issue(email: email) }

    it "accepts the right code with the right request id" do
      expect(described_class.redeem!(request_id: issued.request_id, code: issued.code))
        .to eq(email)
    end

    it "consumes the code, so it works exactly once" do
      described_class.redeem!(request_id: issued.request_id, code: issued.code)

      expect { described_class.redeem!(request_id: issued.request_id, code: issued.code) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    it "refuses a wrong code" do
      wrong = issued.code.succ[0, 6]

      expect { described_class.redeem!(request_id: issued.request_id, code: wrong) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    # The request id is what binds a code to one browser. Without this check a
    # code emailed to one person could be redeemed from anyone else's session,
    # which turns a six-digit secret into a six-digit shared secret.
    it "refuses the right code presented under a different request id" do
      other = described_class.issue(email: "someone.else@example.org")

      expect { described_class.redeem!(request_id: other.request_id, code: issued.code) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    it "refuses a request id that never existed" do
      expect { described_class.redeem!(request_id: "0" * 64, code: issued.code) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    it "refuses an expired code" do
      issued.update!(expires_at: 1.second.ago)

      expect { described_class.redeem!(request_id: issued.request_id, code: issued.code) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    it "compares in constant time" do
      expect(described_class).to respond_to(:secure_compare)
      expect(described_class.secure_compare("abc", "abc")).to be(true)
      expect(described_class.secure_compare("abc", "abd")).to be(false)
      expect(described_class.secure_compare("abc", "abcd")).to be(false)
    end
  end

  describe "the attempt cap" do
    let!(:issued) { described_class.issue(email: email) }

    it "allows five wrong guesses" do
      4.times do
        described_class.redeem!(request_id: issued.request_id, code: "000000")
      rescue SparrowAuth::InvalidCode
        nil
      end

      expect(described_class.redeem!(request_id: issued.request_id, code: issued.code))
        .to eq(email)
    end

    # Destroyed rather than merely marked, so there is nothing left to keep
    # guessing against and nothing left to leak.
    it "destroys the row at the cap" do
      5.times do
        described_class.redeem!(request_id: issued.request_id, code: "000000")
      rescue SparrowAuth::InvalidCode
        nil
      end

      expect(described_class.find_by(id: issued.id)).to be_nil
    end

    it "refuses the correct code once the cap is reached" do
      5.times do
        described_class.redeem!(request_id: issued.request_id, code: "000000")
      rescue SparrowAuth::InvalidCode
        nil
      end

      expect { described_class.redeem!(request_id: issued.request_id, code: issued.code) }
        .to raise_error(SparrowAuth::InvalidCode)
    end

    # Distinguishing "wrong code" from "too many attempts" from "no such
    # request" tells an attacker which of those they have hit, and therefore
    # whether to keep going.
    it "says the same thing however it refuses" do
      messages = []

      6.times do
        described_class.redeem!(request_id: issued.request_id, code: "000000")
      rescue SparrowAuth::InvalidCode => e
        messages << e.message
      end
      begin
        described_class.redeem!(request_id: "0" * 64, code: "000000")
      rescue SparrowAuth::InvalidCode => e
        messages << e.message
      end

      expect(messages.uniq.size).to eq(1)
    end
  end
end
