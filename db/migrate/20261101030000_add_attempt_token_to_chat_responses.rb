class AddAttemptTokenToChatResponses < ActiveRecord::Migration[8.1]
  def change
    add_column :chat_responses, :attempt_token, :uuid, null: false, default: -> { "gen_random_uuid()" }
  end
end
