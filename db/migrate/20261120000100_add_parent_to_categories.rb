class AddParentToCategories < ActiveRecord::Migration[8.1]
  class MigrationCategory < ActiveRecord::Base
    self.table_name = "categories"
  end

  def up
    add_reference :categories, :parent, foreign_key: {to_table: :categories, on_delete: :nullify}
    MigrationCategory.reset_column_information

    YAML.safe_load_file(Rails.root.join("db/category_groups.yml")).each do |parent_name, child_names|
      children = MigrationCategory.where(name: child_names)
      next unless children.exists?

      parent = MigrationCategory.find_or_create_by!(name: parent_name)
      children.update_all(parent_id: parent.id)
    end
  end

  def down
    remove_reference :categories, :parent, foreign_key: {to_table: :categories}
  end
end
