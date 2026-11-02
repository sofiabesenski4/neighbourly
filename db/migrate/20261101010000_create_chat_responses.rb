class CreateChatResponses < ActiveRecord::Migration[8.1]
  def change
    create_table :chat_responses do |t|
      t.references :chat, null: false, index: false, foreign_key: {on_delete: :cascade}
      t.references :user_message, null: false, index: {unique: true}, foreign_key: {to_table: :messages, on_delete: :cascade}
      t.references :assistant_message, foreign_key: {to_table: :messages, on_delete: :nullify}
      t.string :model_id, null: false
      t.string :provider, null: false
      t.string :status, null: false, default: "queued"
      t.text :error_message
      t.datetime :started_at
      t.datetime :finished_at
      t.datetime :heartbeat_at, null: false, default: -> { "CURRENT_TIMESTAMP" }
      t.timestamps
    end

    add_index :chat_responses, [:chat_id, :created_at]
    add_index :chat_responses, :chat_id, unique: true,
      where: "status IN ('queued', 'searching', 'writing')", name: "index_chat_responses_one_active_per_chat"
    add_check_constraint :chat_responses,
      "status IN ('queued', 'searching', 'writing', 'completed', 'failed')", name: "chat_responses_status_check"
  end
end
