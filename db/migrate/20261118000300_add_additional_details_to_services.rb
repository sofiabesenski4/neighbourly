class AddAdditionalDetailsToServices < ActiveRecord::Migration[8.1]
  def change
    # Everything known about a service that has no column of its own, such as
    # eligibility, languages or intake steps. Nothing a source gives is lost.
    add_column :services, :additional_details, :jsonb, default: {}, null: false
  end
end
