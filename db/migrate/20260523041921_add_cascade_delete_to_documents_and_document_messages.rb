class AddCascadeDeleteToDocumentsAndDocumentMessages < ActiveRecord::Migration[8.1]
  def change
    remove_foreign_key :documents, :sources
    add_foreign_key :documents, :sources, on_delete: :cascade

    remove_foreign_key :document_messages, :documents
    add_foreign_key :document_messages, :documents, on_delete: :cascade
  end
end
