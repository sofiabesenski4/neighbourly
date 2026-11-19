class CreateOrganizations < ActiveRecord::Migration[8.1]
  def change
    create_table :organizations do |t|
      t.string :name, null: false
      # The name lowercased with spacing collapsed, so "Our Place " and
      # "our place" are recognised as the same organization.
      t.string :normalized_name, null: false
      t.text :description
      t.string :website
      t.string :email
      t.string :phone
      # Where the organization was first seen. Admins can add one with none.
      t.references :source, foreign_key: {on_delete: :nullify}
      t.timestamps
    end
    add_index :organizations, :normalized_name, unique: true
  end
end
