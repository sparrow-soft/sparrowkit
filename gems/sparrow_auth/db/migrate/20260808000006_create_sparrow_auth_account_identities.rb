# frozen_string_literal: true

# A provider account somebody has deliberately connected to theirs.
#
# The row is the link, and it only ever exists because somebody who was already
# signed in asked for it, or because this provider created the account itself.
# There is no path that creates one by noticing that two email addresses match.
#
# That is the rule this table exists to make enforceable. The audit this was
# drawn from fixed the two failures it found — an unverified provider email being trusted, and
# OAuth accounts being given admin — and left the third in place: it still finds
# an existing account by email and signs the visitor into it. Anybody who can
# persuade any configured provider to assert `email_verified` for an address
# gets that account, so the security of every account rests on the strictness of
# every provider, forever. A link that has to be asked for means a careless
# provider can only reach accounts that chose it.
class CreateSparrowAuthAccountIdentities < ActiveRecord::Migration[7.1]
  def change
    create_table :sparrow_auth_account_identities do |t|
      t.references :account,
        null: false,
        foreign_key: {to_table: :sparrow_auth_accounts, on_delete: :cascade},
        index: false

      t.string :provider, null: false
      t.string :uid, null: false

      # What the provider called the person, kept only so a connections list can
      # say which Google account this is. Never used to find an account.
      # citext on PostgreSQL, a NOCASE collation on SQLite.
      if postgresql?
        t.citext :email
      else
        t.string :email, collation: "NOCASE"
      end

      # Database defaults, because Rodauth writes these rows through Sequel and
      # Sequel does not know about Rails' timestamp conventions. The accounts
      # table needed the same treatment for the same reason.
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # One account per identity. Without this, the same provider account could be
    # connected to two accounts here and which one it signed into would depend
    # on row order.
    add_index :sparrow_auth_account_identities, [:provider, :uid],
      unique: true,
      name: "index_sparrow_auth_identities_on_provider_and_uid"

    # And one connection per provider per account: connecting Google twice is
    # not two things.
    add_index :sparrow_auth_account_identities, [:account_id, :provider],
      unique: true,
      name: "index_sparrow_auth_identities_on_account_and_provider"
  end

  private

  # PostgreSQL or SQLite -- the installer refuses anything else before any
  # migration runs, so these two branches are the whole world.
  def postgresql?
    connection.adapter_name.match?(/\Apostg/i)
  end
end
