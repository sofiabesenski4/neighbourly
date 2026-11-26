class CreateImportConflicts < ActiveRecord::Migration[8.1]
  def change
    create_table :import_conflicts do |t|
      t.references :service, null: false, foreign_key: {on_delete: :cascade}
      # Which detail of the service the changed row would replace, like
      # "phone" or "address".
      t.string :field, null: false
      # What the changed row gives for it. Null when the row leaves it blank.
      t.jsonb :incoming_value
      t.string :status, null: false, default: "pending"
      t.references :decided_by, foreign_key: {to_table: :users, on_delete: :nullify}
      t.datetime :decided_at
      t.timestamps
    end
    # A detail waits on at most one decision. A later import replaces it.
    add_index :import_conflicts, [:service_id, :field], unique: true, where: "status = 'pending'",
      name: "index_import_conflicts_on_pending_service_field"
    add_index :import_conflicts, :status
  end
end
