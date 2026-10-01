class CreateSources < ActiveRecord::Migration[8.1]
  def change
    create_table :sources do |t|
      t.string :name, null: false
      t.string :url, null: false
      t.string :source_type, null: false
      t.string :css_selector
      t.datetime :last_fetched_at

      t.timestamps
    end

    add_index :sources, :url, unique: true
  end
end
