class AddFormerNamesToOrganizations < ActiveRecord::Migration[8.1]
  def change
    # Names an organization went by before it was renamed, normalized like
    # normalized_name. Imports still name it the old way, and should find it
    # rather than create a second organization.
    add_column :organizations, :former_names, :string, array: true, default: [], null: false
    add_index :organizations, :former_names, using: :gin
  end
end
