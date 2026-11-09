class AllowGuestChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :guest_session_digest, :string
    add_index :chats, :guest_session_digest
    change_column_null :chats, :user_id, true
    add_check_constraint :chats, "(user_id IS NULL) <> (guest_session_digest IS NULL)", name: "chats_have_one_owner"
  end
end
