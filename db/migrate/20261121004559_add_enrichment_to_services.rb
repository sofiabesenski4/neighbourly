class AddEnrichmentToServices < ActiveRecord::Migration[8.1]
  def change
    # Enrichment fills in a service's blank details, so it is tracked on the
    # service rather than on the row it was read from. Requested by a source
    # with AI summaries turned on, or by whoever added the service on the site.
    add_column :services, :enrichment_requested, :boolean, default: false, null: false
    add_column :services, :enriched_at, :datetime
    # The model's plain-language description of the service, and its
    # embedding, which is how chat finds the service.
    add_column :services, :enriched_description, :text
    add_column :services, :embedding, :vector, limit: 1536
    # An imported row with no name column waits for enrichment to name it.
    change_column_null :services, :name, true

    # The services found for a chat message, like document_messages for rows.
    create_table :service_messages do |t|
      t.references :service, null: false, foreign_key: {on_delete: :cascade}
      t.references :message, null: false, foreign_key: {on_delete: :cascade}
      t.timestamps
    end
  end
end
