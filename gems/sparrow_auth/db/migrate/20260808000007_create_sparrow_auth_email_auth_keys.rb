# frozen_string_literal: true

# The table behind sign-in links.
#
# One row per account, holding the live link key, when it expires and when the
# last one was sent. Rodauth's email_auth feature owns every one of those
# columns and their names; this creates the table it expects and nothing more.
#
# WHY THIS EXISTS UNCONDITIONALLY, when only half the applications that install
# SparrowKit will use links at all.
#
# The choice between a code and a link is a setting on the control panel, read
# at runtime. If this table only existed for applications that had chosen links,
# then choosing links would leave the application raising until somebody ran a
# migration nobody had told them about — and the symptom would be a missing
# table on the sign-in page, arriving minutes after a change on a settings
# screen that said nothing about databases. A toggle whose real effect is a
# pending migration is not a toggle.
#
# So the table is always here, and is empty in every application that uses
# codes. An empty table costs a row in the schema and nothing else.
#
# A SEVENTH migration rather than a change to one of the six, deliberately.
# Editing a migration that has already run changes nothing on any machine that
# has already run it — the version is recorded, the file is not read again — so
# the developer databases in this repository, and any buyer's, would silently
# lack the table while the schema file claimed otherwise. Phase 2's complaint
# was six migrations altering what earlier ones had created; one more creating
# one more table in its final shape is a different thing.
class CreateSparrowAuthEmailAuthKeys < ActiveRecord::Migration[7.1]
  def change
    # `id: false` with an explicit id column, because the primary key IS the
    # account id rather than a key of its own. One live link per account is the
    # whole design: asking for a second one while the first is alive re-sends
    # the same key rather than issuing another, so a person who clicks "send it
    # again" three times has one link that works and not three.
    create_table :sparrow_auth_email_auth_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.foreign_key :sparrow_auth_accounts, column: :id

      # The key that travels in the link. Rodauth generates and compares it,
      # including the constant-time comparison, and nothing here reimplements
      # any of that.
      t.string :key, null: false

      # When the link stops working. Set from
      # `email_auth_deadline_interval`, which this engine sets to ten minutes to
      # match the code flow rather than leaving Rodauth's default of one day.
      t.datetime :deadline, null: false

      # What Rodauth's own resend throttle reads. Its guard is per account and
      # is a courtesy; the defence is SparrowAuth::RateLimiter, which both
      # mechanisms pass through because both are requested at one seam.
      t.datetime :email_last_sent, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
  end
end
