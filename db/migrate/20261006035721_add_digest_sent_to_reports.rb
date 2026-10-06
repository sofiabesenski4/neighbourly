class AddDigestSentToReports < ActiveRecord::Migration[8.1]
  def change
    add_column :reports, :digest_sent, :boolean, default: false, null: false
    add_index :reports, :digest_sent

    reversible do |dir|
      dir.up do
        execute "UPDATE reports SET digest_sent = true WHERE digest_sent = false"
      end
    end
  end
end
