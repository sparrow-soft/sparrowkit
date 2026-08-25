# frozen_string_literal: true

# A host application's own tenant-scoped table.
#
# The engine's tenancy helpers are only worth what they do to somebody else's
# models, so the suite exercises them against one that lives in the dummy
# application rather than against anything the engine ships.
class CreateWidgets < ActiveRecord::Migration[7.1]
  def change
    create_table :widgets do |t|
      t.string :name, null: false

      # Not null, because a tenant-scoped row with no tenant is invisible to
      # every scoped query and belongs to nobody. Better to refuse the insert.
      t.references :organization,
        null: false,
        foreign_key: {to_table: :sparrow_auth_organizations, on_delete: :cascade}

      t.timestamps
    end
  end
end
