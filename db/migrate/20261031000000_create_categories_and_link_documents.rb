class CreateCategoriesAndLinkDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :categories do |t|
      t.string :name, null: false
      t.index :name, unique: true
      t.timestamps
    end

    create_join_table :categories, :documents do |t|
      t.index [:category_id, :document_id], unique: true
      t.index [:document_id, :category_id], unique: true
    end
    add_foreign_key :categories_documents, :categories, on_delete: :cascade
    add_foreign_key :categories_documents, :documents, on_delete: :cascade
  end
end
