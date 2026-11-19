class CreateServices < ActiveRecord::Migration[8.1]
  def change
    create_table :services do |t|
      t.string :name, null: false
      t.text :description
      t.string :hours
      t.string :phone
      t.string :email
      t.string :website
      # Where it is lives on its address (see Address).
      t.boolean :closed, default: false, null: false
      # Many rows don't say who runs the service, so this can be empty.
      t.references :organization, foreign_key: {on_delete: :nullify}
      t.references :source, null: false, foreign_key: {on_delete: :cascade}
      # The imported row this service was read from. Each row gives at most one.
      t.references :document, foreign_key: {on_delete: :nullify}, index: {unique: true}
      t.timestamps
    end

    create_table :categories_services, id: false do |t|
      t.references :category, null: false, index: false, foreign_key: {on_delete: :cascade}
      t.references :service, null: false, index: false, foreign_key: {on_delete: :cascade}
    end
    add_index :categories_services, [:category_id, :service_id], unique: true
    add_index :categories_services, [:service_id, :category_id], unique: true
  end
end
