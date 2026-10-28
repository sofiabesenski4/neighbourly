# Every chat now answers from ingested community resources, so the per-chat
# opt-in is gone.
class RemoveUseRagFromChats < ActiveRecord::Migration[8.1]
  def change
    remove_column :chats, :use_rag, :boolean, default: false, null: false
  end
end
