# frozen_string_literal: true

# Invitations, bound to an address.
#
# The shape follows the application this was drawn from, which got the hard
# parts right: the token is stored as a digest rather than in the clear, the
# invitation names the address it was issued to, and acceptance is a conditional
# update so two clicks on one link cannot become two memberships.
#
# What that application did not do, and what this exists to fix, is check that
# the accepting account's address was ever *verified*. Without that, registering
# as the invitee and never confirming the address is enough to take their place.
class CreateSparrowAuthInvitations < ActiveRecord::Migration[7.1]
  def change
    create_table :sparrow_auth_invitations do |t|
      # The address this invitation is for. Case-insensitive because an
      # invitation to Victim@example.com and one to victim@example.com are the
      # same invitation, and a case-sensitive comparison here would be a way
      # past the binding. citext on PostgreSQL, a NOCASE collation on SQLite.
      if postgresql?
        t.citext :email, null: false
      else
        t.string :email, null: false, collation: "NOCASE"
      end

      # The token is never stored. What is stored is a digest of it, so a
      # database backup is not a bag of working invitation links.
      t.string :token_digest, null: false

      t.references :invited_by,
        foreign_key: {to_table: :sparrow_auth_accounts, on_delete: :nullify},
        index: true

      t.references :accepted_by,
        foreign_key: {to_table: :sparrow_auth_accounts, on_delete: :nullify},
        index: true

      # The organization this is an invitation *to*, and the role it offers
      # there. Both nullable, because an invitation naming no organization is
      # still a meaningful thing: an invitation to the product, whose effect is
      # whatever the host's after_invitation_accepted hook decides.
      #
      # The organization is on the row rather than inferred because a page
      # listing "the invitations to my organization" needs the row to say which
      # one. Without it the only list that can be drawn is every invitation in
      # the system, which is a cross-tenant leak on a page whose whole purpose
      # is administration.
      t.references :organization,
        null: true,
        index: true,
        foreign_key: {to_table: :sparrow_auth_organizations, on_delete: :cascade}

      t.string :role, null: true

      t.datetime :expires_at, null: false
      t.datetime :accepted_at
      t.timestamps
    end

    add_index :sparrow_auth_invitations, :token_digest, unique: true

    # An invitation cannot be accepted without recording who accepted it. The
    # application layer sets both together; this makes a half-written state
    # impossible even if some future code path forgets one.
    add_check_constraint :sparrow_auth_invitations,
      "(accepted_at IS NULL) = (accepted_by_id IS NULL)",
      name: "sparrow_auth_invitations_accepted_together_check"

    # A role without an organization is a role in nothing. Enforced here as well
    # as in the model, because the model is one code path and the table is the
    # thing that is still true after a console session.
    add_check_constraint :sparrow_auth_invitations,
      "role IS NULL OR organization_id IS NOT NULL",
      name: "sparrow_auth_invitations_role_needs_organization"

    # One live invitation per address, per organization.
    #
    # Two live links to one place means revoking one accomplishes nothing, so
    # re-inviting supersedes rather than accumulates. But an invitation to join
    # Acme and an invitation to join Globex are two different offers to the same
    # person, and a rule that ignored the organization would make issuing the
    # second silently destroy the first.
    #
    # Written as two indexes over disjoint sets of rows rather than one index
    # over both. The reason is that PostgreSQL treats NULLs in a unique index as
    # distinct from one another, so a single (email, organization_id) index
    # would exempt every invitation naming no organization from the rule
    # entirely — which is every invitation to the product. The usual answer to
    # that is NULLS NOT DISTINCT, and it costs a PostgreSQL 15 floor for this
    # one clause; the other is an expression index over COALESCE, which SQLite
    # needs anyway and which no planner can use for an ordinary lookup.
    #
    # Splitting the rule in two needs neither. Both spellings below are plain
    # partial unique indexes that every supported version of both databases
    # understands, they say the same thing between them, and each is usable for
    # the lookups that actually happen: "the pending invitations to this
    # organization for this address", and "the pending product invitation for
    # this address".
    #
    # Whatever supersedes on write must match these two predicates exactly. A
    # supersede narrower than the index leaves a row the index still counts, and
    # the next insert fails with a uniqueness violation on a row nobody can see
    # — which is precisely what an earlier pair of resource columns did, because
    # they were part of the supersede and no part of the index. See
    # SparrowAuth::Invitation.issue.
    add_index :sparrow_auth_invitations, [:email, :organization_id],
      unique: true,
      where: "accepted_at IS NULL AND organization_id IS NOT NULL",
      name: "index_sparrow_auth_invitations_on_email_and_org_pending"

    add_index :sparrow_auth_invitations, :email,
      unique: true,
      where: "accepted_at IS NULL AND organization_id IS NULL",
      name: "index_sparrow_auth_invitations_on_email_pending_no_org"
  end

  private

  # PostgreSQL or SQLite -- the installer refuses anything else before any
  # migration runs, so these two branches are the whole world.
  def postgresql?
    connection.adapter_name.match?(/\Apostg/i)
  end
end
