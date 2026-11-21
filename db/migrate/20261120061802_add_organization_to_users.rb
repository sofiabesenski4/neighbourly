class AddOrganizationToUsers < ActiveRecord::Migration[8.1]
  def change
    # The organization a user is a member of, so they can keep its details
    # and services up to date. Deleting the organization leaves the user.
    add_reference :users, :organization, foreign_key: {on_delete: :nullify}
  end
end
