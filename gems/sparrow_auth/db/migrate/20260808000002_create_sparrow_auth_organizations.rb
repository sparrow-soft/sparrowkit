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

      # The canonical role, not the application's name for it. An application
      # that calls its admins "managers" configures that; renaming a role stays
      # a config change rather than a data migration.
      #
      # There is deliberately no check constraint listing the roles. A list of
      # names in the schema can only ever hold the roles that existed the day it
      # was written, so an application declaring one of its own — an Accountant
      # who reaches billing and nothing else — would fail at the moment somebody
      # was given the role rather than at the moment it was declared, and adding
      # a role would become a deploy.
      #
      # What enforces it instead is SparrowAuth::Membership, which casts through
      # SparrowAuth::Role on the way in and refuses a value no role claims. It
      # also fails closed on the way out: a role nothing declares reads back as
      # nil, which grants nothing, rather than being taken for the weakest role
      # on the ladder.
      #
      # What is lost is real and worth naming: something writing to this table
      # around the model can store a role nobody declared. What is gained is
      # that a role somebody declared can actually be stored.
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
