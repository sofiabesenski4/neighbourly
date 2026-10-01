class CreateDocumentMessages < ActiveRecord::Migration[8.1]
  def change
    create_table :document_messages do |t|
      t.references :document, null: false, foreign_key: true
      t.references :message, null: false, foreign_key: true

      t.timestamps
    end
  end
end
