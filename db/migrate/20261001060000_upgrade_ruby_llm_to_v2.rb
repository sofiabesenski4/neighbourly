# RubyLLM 2.0 owns the model registry and tool calls, and moves message usage
# into its own ledger. Chat history is disposable at this stage, so we clear it
# and go straight to the 2.0 schema instead of running RubyLLM's
# data-preserving upgrade migrations. Users, sources, documents and reports
# are kept.
class UpgradeRubyLlmToV2 < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM active_storage_attachments WHERE record_type = 'Message'"
    execute "TRUNCATE document_messages, tool_calls, messages, chats, models RESTART IDENTITY"

    remove_foreign_key :chats, :models
    remove_foreign_key :messages, :models
    remove_foreign_key :messages, :tool_calls
    drop_table :tool_calls
    drop_table :models

    create_table :ruby_llm_models do |t|
      t.string :model_id, null: false
      t.string :name, null: false
      t.string :provider, null: false
      t.string :family
      t.datetime :model_created_at
      t.integer :context_window
      t.integer :max_output_tokens
      t.date :knowledge_cutoff
      t.jsonb :modalities, default: {}
      t.jsonb :capabilities, default: []
      t.jsonb :pricing, default: {}
      t.jsonb :metadata, default: {}
      t.datetime :unlisted_at
      t.timestamps

      t.index [:provider, :model_id], unique: true
      t.index :provider
      t.index :family
      t.index :capabilities, using: :gin
      t.index :modalities, using: :gin
    end

    create_table :ruby_llm_tool_calls do |t|
      t.references :message, polymorphic: true, null: false, index: false
      t.references :result, polymorphic: true, index: false
      t.string :tool_call_id, null: false
      t.string :name, null: false
      t.jsonb :arguments, default: {}
      t.text :thought_signature
      t.string :approval
      t.boolean :remote, default: false, null: false
      t.timestamps

      t.index [:message_type, :message_id]
      t.index [:result_type, :result_id]
      t.index :tool_call_id, unique: true
      t.index :name
    end

    create_table :ruby_llm_usages do |t|
      t.references :chat, polymorphic: true, null: false, index: false
      t.references :message, polymorphic: true, index: false
      t.string :operation, null: false
      t.string :status, null: false
      t.string :provider, null: false
      t.string :model, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.integer :cache_read_tokens
      t.integer :cache_write_tokens
      t.integer :thinking_tokens
      t.decimal :input_cost, precision: 16, scale: 10
      t.decimal :output_cost, precision: 16, scale: 10
      t.decimal :cache_read_cost, precision: 16, scale: 10
      t.decimal :cache_write_cost, precision: 16, scale: 10
      t.decimal :thinking_cost, precision: 16, scale: 10
      t.decimal :total_cost, precision: 16, scale: 10
      t.timestamps

      t.index [:chat_type, :chat_id]
      t.index [:message_type, :message_id]
      t.index :status
      t.check_constraint "operation IN ('chat', 'embedding', 'moderation', 'image', 'speech', 'transcription', 'ocr', 'rerank')"
      t.check_constraint "status IN ('pending', 'succeeded', 'failed', 'cancelled')"
    end

    create_table :ruby_llm_batches do |t|
      t.string :provider, null: false
      t.string :provider_batch_id, null: false
      t.string :batch_protocol
      t.string :status, null: false
      t.string :raw_status
      t.boolean :completed, default: false, null: false
      t.string :chat_type
      t.jsonb :chat_ids, default: []
      t.jsonb :request_counts
      t.jsonb :reported_cost
      t.timestamps

      t.index [:provider, :provider_batch_id], unique: true
      t.index :status
    end

    remove_column :chats, :model_id
    add_column :chats, :cancelled, :boolean, default: false, null: false
    add_reference :chats, :ruby_llm_model, foreign_key: true

    remove_index :messages, :role
    remove_columns :messages, :model_id, :tool_call_id, :content_raw, :input_tokens,
      :output_tokens, :cached_tokens, :cache_creation_tokens, :thinking_tokens
    add_column :messages, :cache_until_here, :boolean, default: false, null: false
    add_column :messages, :citations, :jsonb
    add_column :messages, :finish_reason, :string
    add_column :messages, :raw_content, :jsonb
    add_column :messages, :raw_reasoning, :jsonb
    add_column :messages, :server_tool_calls, :jsonb
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
