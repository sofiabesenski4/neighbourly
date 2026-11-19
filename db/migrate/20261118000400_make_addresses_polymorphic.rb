class MakeAddressesPolymorphic < ActiveRecord::Migration[8.1]
  # Services and organizations have addresses too, so an address belongs to
  # whichever record it locates instead of only to a document. Its
  # coordinates stay here, never on the record itself.
  def change
    remove_reference :addresses, :document, null: false, index: {unique: true}, foreign_key: {on_delete: :cascade}
    add_reference :addresses, :addressable, polymorphic: true, null: false, index: {unique: true}
    add_column :addresses, :province, :string
    add_column :addresses, :postal_code, :string
    add_column :addresses, :country, :string
  end
end
