class ChangeUserNullableOnReports < ActiveRecord::Migration[8.1]
  def change
    change_column_null :reports, :user_id, true
  end
end
