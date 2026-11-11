class CreateAddresses < ActiveRecord::Migration[8.1]
  def change
    create_table :addresses do |t|
      t.references :document, null: false, index: {unique: true}, foreign_key: {on_delete: :cascade}
      t.string :street_address
      t.string :city
      t.string :phone
      t.float :lat
      t.float :lng
      t.timestamps
    end
  end
end
