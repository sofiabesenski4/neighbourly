class RemoveIndexOnUrlFromSources < ActiveRecord::Migration[8.1]
  def change
    remove_index :sources, :url, unique: true, name: "index_sources_on_url"
  end
end
