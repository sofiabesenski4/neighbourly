class RemoveCssSelectorFromSources < ActiveRecord::Migration[8.1]
  def change
    remove_column :sources, :css_selector, :string
  end
end
