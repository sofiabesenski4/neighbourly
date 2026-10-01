class ChangeUrlNullableOnSources < ActiveRecord::Migration[8.1]
  def change
    change_column_null :sources, :url, true
  end
end
