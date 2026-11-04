# Uploads are ingested in a background job. The source holds the uploaded file
# until then, and records how ingestion went so admins can see it.
class AddIngestionTrackingToSources < ActiveRecord::Migration[8.1]
  def up
    add_column :sources, :ingestion_status, :string
    add_column :sources, :ingestion_error, :text
    # Raw bytes, since uploads may not be valid UTF-8 until a parser reads them.
    add_column :sources, :upload_content, :binary

    # Every existing upload was ingested during its request, so it already
    # finished. Form entries are not ingested and keep no status.
    execute "UPDATE sources SET ingestion_status = 'succeeded' WHERE source_type <> 'form'"
  end

  def down
    # A held upload is the only copy of a file that is waiting or failed.
    if select_value("SELECT COUNT(*) FROM sources WHERE upload_content IS NOT NULL").to_i.positive?
      raise ActiveRecord::IrreversibleMigration, "Sources still hold uploads. Ingest or delete them before rolling back."
    end

    remove_column :sources, :upload_content
    remove_column :sources, :ingestion_error
    remove_column :sources, :ingestion_status
  end
end
