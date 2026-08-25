# frozen_string_literal: true

require "rails_helper"
require "rake"

# The two tables that grow forever, and the task that stops them.
#
# Both hold an email address beside something else — an IP address, the digest
# of a sign-in code — and neither had anything deleting from it. What made that
# a data-retention problem rather than a disk-space one is that the rows keep
# their meaning: a year of auth_events is a record of who tried to sign in to
# what, and from where.
#
# The dangerous half of a pruning task is deleting a row that was still in use,
# so both directions are asserted here: what goes, and what stays.
RSpec.describe "sparrow_auth:prune" do
  before do
    Rake::Task.clear
    Rake::TaskManager.record_task_metadata = true
    load SparrowAuth::Engine.root.join("lib/tasks/sparrow_auth_prune.rake").to_s
    Rake::Task.define_task(:environment)
  end

  after { Rake::Task.clear }

  # Captured rather than let through, because the task's whole output is one
  # line to a person and a suite that prints it once per example is noise.
  # Returned, so the examples that are about the message can read it.
  def run!
    captured = StringIO.new
    original = $stdout
    $stdout = captured
    Rake::Task["sparrow_auth:prune"].tap(&:reenable).invoke
    captured.string
  ensure
    $stdout = original
  end

  def event(bucket:, subject:, age:)
    SparrowAuth::AuthEvent.create!(bucket: bucket, subject: subject).tap do |row|
      SparrowAuth::AuthEvent.where(id: row.id).update_all(created_at: age.ago)
    end
  end

  # The widest window any budget uses. Read from the budgets rather than
  # written here, for the same reason the task reads it: a number copied into
  # two places is a number that will disagree with itself.
  let(:widest) { SparrowAuth::RateLimiter::BUDGETS.values.flatten.map(&:window).max }

  describe "rate-limit counters" do
    it "deletes one older than every budget's window" do
      old = event(bucket: "otp_send:email", subject: "old@example.org", age: widest + 1.hour)

      expect(run!).to match(/1 rate-limit counter/)
      expect(SparrowAuth::AuthEvent.exists?(old.id)).to be(false)
    end

    # The half that matters. A counter still inside its window is what a rate
    # limit is made of, and deleting it hands the budget back to whoever was
    # being throttled.
    it "leaves one that a budget is still counting" do
      recent = event(bucket: "otp_send:email", subject: "live@example.org", age: 5.seconds)

      run!

      expect(SparrowAuth::AuthEvent.exists?(recent.id)).to be(true)
    end

    it "does not let a throttled address back in" do
      SparrowAuth::RateLimiter.record(bucket: "otp_send:email", subject: "loud@example.org")

      run!

      expect(SparrowAuth::RateLimiter.allowed?(bucket: "otp_send:email", subject: "loud@example.org"))
        .to be(false)
    end
  end

  describe "sign-in codes" do
    it "deletes one that has expired" do
      _code = SparrowAuth::OneTimeCode.issue(email: "gone@example.org")
      SparrowAuth::OneTimeCode.update_all(expires_at: 1.minute.ago)

      expect(run!).to match(/1 expired sign-in code/)
      expect(SparrowAuth::OneTimeCode.count).to eq(0)
    end

    it "leaves one that can still be redeemed" do
      SparrowAuth::OneTimeCode.issue(email: "live@example.org")

      run!

      expect(SparrowAuth::OneTimeCode.count).to eq(1)
    end
  end

  # What it deleted is exactly the personal data the task exists to remove, so
  # printing any of it would defeat the point of running it.
  it "reports counts and never an address" do
    event(bucket: "otp_send:email", subject: "secret@example.org", age: widest + 1.hour)
    SparrowAuth::OneTimeCode.issue(email: "secret@example.org")
    SparrowAuth::OneTimeCode.update_all(expires_at: 1.minute.ago)

    expect(run!).not_to include("secret@example.org")
  end
end
