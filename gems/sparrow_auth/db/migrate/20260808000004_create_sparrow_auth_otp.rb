# frozen_string_literal: true

# Email one-time codes, and the counters that limit them.
#
# The shape follows the application this was drawn from, with the fixes its
# audit called for applied. Two of those are visible here in the schema rather
# than in code, which is where they belong.
#
# First, rate-limit counters carry an explicit bucket. That application counted
# send and verify attempts in one undifferentiated table, so a verify attempt
# inserted a row that the send limiter's per-IP query then counted. Verifying consumed the
# budget for sending, and on shared WiFi that silently locked people out of
# their own accounts. A bucket column makes the budgets independent by
# construction rather than by everyone remembering to filter.
#
# Second, the code digest and the request id are separate columns with separate
# jobs. The request id is an opaque lookup handle bound to one browser by a
# cookie; the digest is the secret. Knowing one must not help with the other.
class CreateSparrowAuthOtp < ActiveRecord::Migration[7.1]
  def change
    create_table :sparrow_auth_otp_codes do |t|
      # Case-insensitive for the same reason the accounts table is: a code
      # requested for Victim@example.com must be the code for
      # victim@example.com. citext on PostgreSQL, a NOCASE collation on SQLite.
      if postgresql?
        t.citext :email, null: false
      else
        t.string :email, null: false, collation: "NOCASE"
      end

      # Never the code. An HMAC-SHA256 digest keyed on a dedicated secret, so a
      # database backup is not a list of working sign-in codes, and so an
      # attacker with the table cannot brute-force the six digits offline
      # without also having the key.
      t.string :code_digest, null: false

      # Opaque, 32 random bytes. Bound to one browser by a host-only cookie, and
      # used only for lookup: tamper resistance comes from having to match a row
      # that also matches the cookie, not from the value being signed.
      t.string :request_id, null: false

      t.datetime :expires_at, null: false
      t.integer :attempts, null: false, default: 0
      t.datetime :consumed_at

      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :sparrow_auth_otp_codes, :request_id, unique: true
    add_index :sparrow_auth_otp_codes, [:email, :consumed_at]

    # The only column `sparrow_auth:prune` looks at, and the reason this table
    # does not grow forever. Without it, pruning a table nobody has pruned yet
    # reads every row of it — which is the one moment it is largest, and the one
    # moment somebody is watching a production console wondering whether to
    # cancel. Deleting a code the moment it expires also matters more here than
    # a stray index does: an unconsumed code is an email address sitting beside
    # a secret with nothing left to do.
    add_index :sparrow_auth_otp_codes, :expires_at

    add_check_constraint :sparrow_auth_otp_codes,
      "attempts >= 0",
      name: "sparrow_auth_otp_codes_attempts_check"

    create_table :sparrow_auth_auth_events do |t|
      # The namespace. "otp_send:email", "otp_send:ip", "otp_verify:ip". The
      # table this replaces had no equivalent, which is precisely how its verify
      # attempts came to be counted against its send budget.
      t.string :bucket, null: false

      # Whatever the bucket counts by: an address, an IP. Never both in one row,
      # so one kind of event cannot be counted as another.
      t.string :subject, null: false

      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_index :sparrow_auth_auth_events, [:bucket, :subject, :created_at],
      name: "index_sparrow_auth_auth_events_on_bucket_subject_time"

    # Deliberately no second index on created_at alone, even though
    # `sparrow_auth:prune` filters on exactly that.
    #
    # This is the most-written table in the engine — every sign-in attempt of
    # every kind inserts a row — and every index is a cost paid on each of those
    # writes. The widest budget in SparrowAuth::RateLimiter is an hour, so a
    # prune run on any sane schedule is deleting almost the whole table, and a
    # scan is the right plan for that rather than a detour through an index.
  end

  private

  # PostgreSQL or SQLite -- the installer refuses anything else before any
  # migration runs, so these two branches are the whole world.
  def postgresql?
    connection.adapter_name.match?(/\Apostg/i)
  end
end
