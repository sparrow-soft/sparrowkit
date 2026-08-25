# frozen_string_literal: true

require "rails_helper"

# The budgets, and above all their independence.
#
# One earlier application counted send and verify attempts in one undifferentiated table, so a
# verify attempt inserted a row that the send limiter's per-IP query counted.
# Verifying consumed the budget for sending. On shared WiFi, a venue full of
# people signing in locked each other out, and it looked like nothing at all in
# the logs.
#
# So the first thing tested here is not any individual limit but that the
# budgets cannot see each other.
RSpec.describe SparrowAuth::RateLimiter do
  describe "budget independence" do
    it "does not let verify attempts consume the send budget" do
      described_class::VERIFY_PER_IP.limit.times do
        described_class.record(bucket: "otp_verify:ip", subject: "203.0.113.7")
      end

      expect(described_class).to be_allowed(bucket: "otp_send:ip", subject: "203.0.113.7")
    end

    it "does not let send attempts consume the verify budget" do
      described_class::SEND_PER_IP.limit.times do
        described_class.record(bucket: "otp_send:ip", subject: "203.0.113.7")
      end

      expect(described_class).to be_allowed(bucket: "otp_verify:ip", subject: "203.0.113.7")
    end

    it "does not let one address's sends consume another's" do
      described_class::SEND_PER_EMAIL_HOUR.limit.times do
        described_class.record(bucket: "otp_send:email", subject: "busy@example.org")
      end

      expect(described_class).to be_allowed(bucket: "otp_send:email", subject: "quiet@example.org")
    end

    it "does not let an address's sends consume an IP's budget" do
      described_class::SEND_PER_EMAIL_HOUR.limit.times do
        described_class.record(bucket: "otp_send:email", subject: "busy@example.org")
      end

      expect(described_class).to be_allowed(bucket: "otp_send:ip", subject: "busy@example.org")
    end
  end

  describe "the documented budgets" do
    it "allows one send per address per minute" do
      described_class.record(bucket: "otp_send:email", subject: "person@example.org")

      expect(described_class).not_to be_allowed(bucket: "otp_send:email", subject: "person@example.org")
    end

    it "allows another once the minute has passed" do
      described_class.record(bucket: "otp_send:email", subject: "person@example.org")
      SparrowAuth::AuthEvent.update_all(created_at: 61.seconds.ago)

      expect(described_class).to be_allowed(bucket: "otp_send:email", subject: "person@example.org")
    end

    it "allows five sends per address per hour" do
      5.times do |i|
        described_class.record(bucket: "otp_send:email", subject: "person@example.org")
        SparrowAuth::AuthEvent.last.update!(created_at: (i + 1).minutes.ago)
      end

      expect(described_class).not_to be_allowed(bucket: "otp_send:email", subject: "person@example.org")
    end

    it "allows ten sends per IP per hour" do
      10.times { described_class.record(bucket: "otp_send:ip", subject: "203.0.113.7") }

      expect(described_class).not_to be_allowed(bucket: "otp_send:ip", subject: "203.0.113.7")
    end

    it "allows ten verifies per IP per fifteen minutes" do
      10.times { described_class.record(bucket: "otp_verify:ip", subject: "203.0.113.7") }

      expect(described_class).not_to be_allowed(bucket: "otp_verify:ip", subject: "203.0.113.7")
    end

    it "forgets verify attempts older than the window" do
      10.times { described_class.record(bucket: "otp_verify:ip", subject: "203.0.113.7") }
      SparrowAuth::AuthEvent.update_all(created_at: 16.minutes.ago)

      expect(described_class).to be_allowed(bucket: "otp_verify:ip", subject: "203.0.113.7")
    end
  end

  # One earlier application exempted two hardcoded addresses, one of them the owner's own. An
  # exemption is a bypass that lives forever, is never revisited, and is exactly
  # what an attacker would target first if they learned of it.
  describe "exemptions" do
    it "has none, for any address" do
      expect(described_class).not_to respond_to(:exempt?)
      expect(described_class.constants.map(&:to_s).grep(/EXEMPT/i)).to be_empty
    end

    it "rate-limits every address the same way" do
      ["owner@example.org", "admin@example.org", "anyone@example.org"].each do |address|
        described_class.record(bucket: "otp_send:email", subject: address)

        expect(described_class).not_to be_allowed(bucket: "otp_send:email", subject: address),
          "#{address} was not rate limited"
      end
    end
  end
end
