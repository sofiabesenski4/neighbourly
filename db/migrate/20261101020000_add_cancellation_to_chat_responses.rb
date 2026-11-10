class AddCancellationToChatResponses < ActiveRecord::Migration[8.1]
  def up
    replace_status_constraints(%w[queued searching writing cancelling completed failed cancelled], %w[queued searching writing cancelling])
  end

  def down
    execute "UPDATE chat_responses SET status = 'failed' WHERE status IN ('cancelling', 'cancelled')"
    replace_status_constraints(%w[queued searching writing completed failed], %w[queued searching writing])
  end

  private

  def replace_status_constraints(statuses, active_statuses)
    remove_check_constraint :chat_responses, name: "chat_responses_status_check"
    remove_index :chat_responses, name: "index_chat_responses_one_active_per_chat"
    add_check_constraint :chat_responses, "status IN (#{statuses.map { |status| connection.quote(status) }.join(", ")})",
      name: "chat_responses_status_check"
    add_index :chat_responses, :chat_id, unique: true,
      where: "status IN (#{active_statuses.map { |status| connection.quote(status) }.join(", ")})",
      name: "index_chat_responses_one_active_per_chat"
  end
end
