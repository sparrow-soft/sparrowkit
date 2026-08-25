# frozen_string_literal: true

# Rodauth's account tables, namespaced to the engine.
#
# The shapes are Rodauth's, not ours: it writes these through Sequel and expects
# these columns. What is ours is the namespacing, so mounting this engine cannot
# collide with a host application's own `accounts` table, and the constraints
# that make the database refuse states the application layer might otherwise
# allow.
class CreateSparrowAuthAccounts < ActiveRecord::Migration[7.1]
  def change
    # Case-insensitive addresses at the database level. Comparing addresses in
    # Ruby instead means every call site has to remember to downcase, and the
    # one that forgets is how "Victim@example.com" becomes a second account for
    # an address that already exists. citext on PostgreSQL; on SQLite the
    # NOCASE collation gives the same lookups and the same unique index.
    enable_extension "citext" if postgresql? && !extension_enabled?("citext")

    create_table :sparrow_auth_accounts do |t|
      t.integer :status_id, null: false, default: 1
      if postgresql?
        t.citext :email, null: false
      else
        t.string :email, null: false, collation: "NOCASE"
      end

      # When this account first got in, so that "on first sign-in" can be a fact
      # rather than a guess.
      #
      # The alternative is inferring it — no active sessions yet, or no rows in
      # some other table — and every such inference is wrong at least once. A
      # session table that is pruned makes a returning account look new, and
      # provisioning hooks that run twice are how an application ends up with
      # two organizations for one person.
      #
      # Nullable, and set exactly once. The transition from NULL is the event.
      t.datetime :first_signed_in_at

      # Database defaults rather than t.timestamps, because this table is
      # written by two ORMs. Rodauth inserts through Sequel, which knows nothing
      # about Active Record's timestamp convention, so a NOT NULL column with no
      # default makes every signup fail on a constraint the application layer
      # thought it was filling in.
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :updated_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    # 1 unverified, 2 verified, 3 closed. A check constraint rather than a
    # foreign key to a three-row lookup table, which would buy nothing.
    add_check_constraint :sparrow_auth_accounts,
      "status_id IN (1, 2, 3)",
      name: "sparrow_auth_accounts_status_id_check"

    # Unique among accounts that still exist. A closed account keeps its row for
    # audit, and must not block the address from being used again.
    add_index :sparrow_auth_accounts, :email,
      unique: true,
      where: "status_id IN (1, 2)",
      name: "index_sparrow_auth_accounts_on_email_live"

    # And a plain one, because the partial index above cannot serve a lookup.
    #
    # `Account.find_by_email` asks for an address and nothing else — on purpose,
    # because a closed account has to be *found* in order to be refused, and an
    # address lookup that skipped closed accounts would report the address as
    # free and let a second account be made for it. A partial index can only be
    # used by a query the planner can prove stays inside the index's own WHERE,
    # and this query says nothing about status, so PostgreSQL sequentially scans
    # the table on the single hottest read path the engine has. Measured at
    # 200,000 accounts: 13.5 ms scanning, 0.48 ms with this index.
    #
    # It does not shadow the index above and is not shadowed by it: that one
    # enforces a rule, this one answers a question.
    add_index :sparrow_auth_accounts, :email,
      name: "index_sparrow_auth_accounts_on_email"

    create_table :sparrow_auth_account_password_hashes, id: false do |t|
      t.bigint :id, primary_key: true
      t.string :password_hash, null: false
    end
    add_foreign_key :sparrow_auth_account_password_hashes, :sparrow_auth_accounts,
      column: :id, on_delete: :cascade

    create_table :sparrow_auth_account_verification_keys, id: false do |t|
      t.bigint :id, primary_key: true
      t.string :key, null: false
      t.datetime :requested_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :email_last_sent, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end
    add_foreign_key :sparrow_auth_account_verification_keys, :sparrow_auth_accounts,
      column: :id, on_delete: :cascade

    # Database-backed sessions, which is what makes them revocable. A session
    # that exists only as a signed cookie cannot be withdrawn, only waited out.
    create_table :sparrow_auth_account_active_session_keys, primary_key: %i[account_id session_id] do |t|
      t.bigint :account_id
      t.string :session_id
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.datetime :last_use, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Something to recognise a session by.
      #
      # Started-at and last-used are enough to notice that one of these is not
      # yours only if you happen to be looking at the right moment. A list of
      # four identical rows is not something anybody can act on, and "revoke the
      # one that is not me" is the entire point of showing the list.
      #
      # The user agent and nothing else. It is sent by the client on every
      # request already, so storing it discloses nothing new. IP addresses are
      # deliberately not kept: they would need a geolocation service to mean
      # anything to a person, and "last used four minutes ago on a browser you
      # do not recognise" plus a button that ends every other session covers the
      # actual need without keeping a movement log on everybody.
      t.string :user_agent, limit: 255
    end
    add_foreign_key :sparrow_auth_account_active_session_keys, :sparrow_auth_accounts,
      column: :account_id, on_delete: :cascade
    # No separate index on account_id: it leads the composite primary key, so
    # "this account's sessions" and the foreign key are both already served.
  end

  private

  # PostgreSQL or SQLite -- the installer refuses anything else before any
  # migration runs, so these two branches are the whole world.
  def postgresql?
    connection.adapter_name.match?(/\Apostg/i)
  end
end
