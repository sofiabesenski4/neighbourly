class AddConfirmationToServices < ActiveRecord::Migration[8.1]
  def change
    # When someone last checked a service's details were right, who did, and
    # how, like a phone call or its website. People reading a printout use
    # this to judge how far to trust it.
    add_column :services, :confirmed_at, :datetime
    add_column :services, :confirmation_method, :string
    add_reference :services, :confirmed_by, foreign_key: {to_table: :users, on_delete: :nullify}
  end
end
