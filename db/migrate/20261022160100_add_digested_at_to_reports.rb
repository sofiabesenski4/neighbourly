class AddDigestedAtToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :digested_at, :datetime
    add_index :reports, :digested_at
  end
end
