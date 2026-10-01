class CreateDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :documents do |t|
      t.references :source, null: false, foreign_key: true
      t.string :title
      t.text :content, null: false
      t.jsonb :metadata, default: {}
      t.string :external_id
      t.vector :embedding, limit: 1536

      t.timestamps
    end

    add_index :documents, [:source_id, :external_id], unique: true
  end
end
