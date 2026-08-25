# frozen_string_literal: true

# Passkeys.
#
# Two tables, both shaped by Rodauth rather than by us. The user-ids table holds
# the opaque handle presented to authenticators; the keys table holds one row per
# enrolled credential.
#
# The handle is deliberately not the account id. WebAuthn sends the user handle
# to the authenticator, where it is stored and can be read back by anything that
# can talk to it, so putting a database id in there leaks the id and links a
# person's credentials across relying parties. A random handle leaks nothing.
class CreateSparrowAuthWebauthnKeys < ActiveRecord::Migration[7.1]
  def change
    create_table :sparrow_auth_account_webauthn_user_ids, id: false do |t|
      t.bigint :id, null: false, primary_key: true
      t.text :webauthn_id, null: false
    end

    add_foreign_key :sparrow_auth_account_webauthn_user_ids, :sparrow_auth_accounts,
      column: :id, on_delete: :cascade

    # Composite primary key, because a credential is identified by the pair. The
    # same authenticator enrolled on two accounts is two rows, and neither the
    # account nor the credential id alone identifies one.
    create_table :sparrow_auth_account_webauthn_keys,
      primary_key: [:account_id, :webauthn_id] do |t|
      t.bigint :account_id, null: false
      t.text :webauthn_id, null: false
      t.text :public_key, null: false

      # The authenticator's counter, checked on every assertion. A counter that
      # goes backwards means the credential has been cloned, which is the one
      # thing this column exists to catch. All three applications this replaces
      # got this right; it is the only part of WebAuthn all three got right.
      t.bigint :sign_count, null: false

      t.datetime :last_use, null: false, default: -> { "CURRENT_TIMESTAMP" }

      # Ours, not Rodauth's. A person with three passkeys sees three identical
      # rows otherwise, and cannot tell which one is the laptop they just lost.
      t.string :nickname
      t.datetime :created_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
    end

    add_foreign_key :sparrow_auth_account_webauthn_keys, :sparrow_auth_accounts,
      column: :account_id, on_delete: :cascade
  end
end
