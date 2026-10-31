class AddCategoriesToDocuments < ActiveRecord::Migration[8.1]
  def up
    add_column :documents, :categories, :string, array: true, default: [], null: false

    execute <<~SQL
      UPDATE documents
      SET categories = ARRAY(
        SELECT jsonb_array_elements_text(metadata->'categories')
      ),
      metadata = metadata - 'categories'
      WHERE jsonb_typeof(metadata->'categories') = 'array'
    SQL
  end

  def down
    execute <<~SQL
      UPDATE documents
      SET metadata = jsonb_set(metadata, '{categories}', to_jsonb(categories), true)
    SQL

    remove_column :documents, :categories, :string, array: true, default: [], null: false
  end
end
