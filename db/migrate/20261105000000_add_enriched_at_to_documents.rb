class AddEnrichedAtToDocuments < ActiveRecord::Migration[8.1]
  def change
    add_column :documents, :enriched_at, :datetime
  end
end
