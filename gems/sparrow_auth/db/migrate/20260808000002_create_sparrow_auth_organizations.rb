# frozen_string_literal: true

# Organizations and memberships.
#
# Ahead of invitations, because an invitation points at an organization.
#
# Two things this deliberately does not copy from the applications it was drawn
# from.
#
# One puts `belongs_to :organization` on the user; another enforced a strict
# one-to-one in the schema. Both are reasonable for those applications and
# neither can be undone later without a migration and a rewrite of every query
# that assumed it. An engine cannot make that choice on an application's behalf,
# so membership is a join table from the start. An application that wants one
# organization per account enforces that in its own code, where it can change
# its mind.
#
# And the organization row holds identity, not settings. The table it was drawn
# from carried a dozen columns of one business's own configuration — exactly
# right for that business, and none of an auth engine's business. Applications
# add their own columns or their own table; this one stays small enough that
# every application can live with it.
class CreateSparrowAuthOrganizations < ActiveRecord::Migration[7.1]
  def change
    create_table :sparrow_auth_organizations do |t|
      t.string :name, null: false

      # Slugs are identity, not decoration: the commonest way to resolve the
      # current organization is from the URL, and that needs a stable handle
      # that is not the primary key. Case-insensitive for the same reason
      # emails are — /acme and /ACME must not be two different tenants. citext
      # on PostgreSQL, a NOCASE collation on SQLite.
      if postgresql?
        t.citext :slug, null: false
      else
        t.string :slug, null: false, collation: "NOCASE"
      end

      t.timestamps
    end

    add_index :sparrow_auth_organizations, :slug, unique: true

    create_table :sparrow_auth_memberships do |t|
      t.references :account,
        null: false,
        foreign_key: {to_table: :sparrow_auth_accounts, on_delete: :cascade},
        index: false

      t.references :organization,
        null: false,
        foreign_key: {to_table: :sparrow_auth_organizations, on_delete: :cascade},
        index: true

      # A role name the application chose. SparrowKit stores it and never
      # interprets it: there is no ladder here and no notion of one role
      # outranking another.
      #
      # There is deliberately no check constraint listing the roles, and nothing
      # anywhere that enumerates them. A list of names in the schema can only
      # ever hold the roles that existed the day it was written, so an
      # application declaring one of its own -- an Accountant who reaches
      # billing and nothing else -- would fail at the moment somebody was given
      # the role rather than when it was declared, and adding a role would
      # become a deploy.
      #
      # What that costs is real and worth naming: this column will hold any
      # string, so a typo is storable. What it buys is that deciding what a role
      # means stays in the application, where the only code that knows lives.
      t.string :role, null: false

      t.timestamps
    end

    # One membership per account per organization. Without this, "add them to
    # the org" run twice is two rows, and which role applies then depends on
    # which row a query happens to load first.
    #
    # It leads with account_id, which is why the reference above asks for no
    # index of its own: "which organizations is this account in" is served here.
    add_index :sparrow_auth_memberships, [:account_id, :organization_id],
      unique: true,
      name: "index_sparrow_auth_memberships_on_account_and_organization"
  end

  private

  # PostgreSQL or SQLite -- the installer refuses anything else before any
  # migration runs, so these two branches are the whole world.
  def postgresql?
    connection.adapter_name.match?(/\Apostg/i)
  end
end
