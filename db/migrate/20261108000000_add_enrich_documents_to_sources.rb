# Enrichment calls an LLM for every row, which costs money and rewrites each
# document's text. Admins opt in per source, so existing sources stay off.
class AddEnrichDocumentsToSources < ActiveRecord::Migration[8.1]
  def change
    add_column :sources, :enrich_documents, :boolean, default: false, null: false
  end
end
