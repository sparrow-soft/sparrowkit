# frozen_string_literal: true

# A host application's resource that names its organization and is not tenant
# scoped.
#
# It sits beside widgets, which is, so the suite can show the difference.
# Tenanted answers "which rows may this tenant see" with a scope; a model that
# opts out of it is reached by id, and is then guarded by the controller like
# anything else. Neither layer substitutes for the other.
class CreateProjects < ActiveRecord::Migration[7.1]
  def change
    create_table :projects do |t|
      t.string :name, null: false

      t.references :organization,
        null: false,
        foreign_key: {to_table: :sparrow_auth_organizations, on_delete: :cascade}

      t.timestamps
    end
  end
end
