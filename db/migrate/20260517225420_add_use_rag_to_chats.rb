class AddUseRagToChats < ActiveRecord::Migration[8.1]
  def change
    add_column :chats, :use_rag, :boolean, default: false, null: false
  end
end
