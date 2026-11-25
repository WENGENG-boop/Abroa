class CreateAbroaAiFinancialAssistant < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_ai_model_providers, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :owner, null: false, type: :uuid,
        foreign_key: { to_table: :users, on_delete: :cascade }, index: { unique: true }
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.string :base_url, null: false
      t.string :model_identifier, null: false
      t.text :api_key
      t.jsonb :capabilities, default: {}, null: false
      t.boolean :disabled, null: false, default: false
      t.string :setup_key_digest, null: false
      t.string :setup_request_digest, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
    end

    create_table :abroa_ai_model_usages, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :owner, null: false, type: :uuid,
        foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :family, null: false, type: :uuid,
        foreign_key: { on_delete: :cascade }
      t.references :provider, type: :uuid,
        foreign_key: { to_table: :abroa_ai_model_providers, on_delete: :nullify }
      t.string :model_identifier, null: false
      t.string :status, null: false
      t.integer :input_tokens
      t.integer :output_tokens
      t.decimal :cost_usd, precision: 18, scale: 8
      t.integer :latency_ms
      t.string :failure_kind
      t.timestamps
      t.index [ :owner_id, :created_at ]
    end
    add_check_constraint :abroa_ai_model_usages,
      "status IN ('success','failed','timeout') AND " \
      "(input_tokens IS NULL OR input_tokens >= 0) AND " \
      "(output_tokens IS NULL OR output_tokens >= 0) AND " \
      "(cost_usd IS NULL OR cost_usd >= 0) AND " \
      "(latency_ms IS NULL OR latency_ms >= 0)",
      name: "abroa_ai_usage_valid"

    create_table :abroa_ai_operation_proposals, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid,
        foreign_key: { on_delete: :cascade }
      t.references :owner, null: false, type: :uuid,
        foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :project, type: :uuid,
        foreign_key: { to_table: :abroa_study_projects, on_delete: :restrict }
      t.string :operation, null: false
      t.string :resource_type, null: false
      t.uuid :resource_id, null: false
      t.jsonb :parameters, null: false, default: {}
      t.jsonb :before_snapshot, null: false, default: {}
      t.integer :expected_resource_version, null: false
      t.string :expected_state_digest, null: false
      t.string :execution_state_digest
      t.string :confirmation_digest, null: false
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.string :status, null: false, default: "proposed"
      t.datetime :expires_at, null: false
      t.datetime :confirmed_at
      t.datetime :executed_at
      t.datetime :compensated_at
      t.uuid :execution_resource_id
      t.integer :execution_resource_version
      t.integer :lock_version, default: 0, null: false
      t.timestamps
      t.index [ :owner_id, :creation_key_digest ], unique: true,
        name: "idx_abroa_ai_proposal_idempotency"
      t.index [ :owner_id, :status, :expires_at ]
    end
    add_check_constraint :abroa_ai_operation_proposals,
      "status IN ('proposed','confirmed','executed','rejected','compensated','cancelled') AND " \
      "operation IN ('budget_update','fee_adjust','pool_allocate','entry_classify','import_match','parent_budget_suggestion') AND " \
      "expected_resource_version >= 0",
      name: "abroa_ai_proposal_valid"
  end
end
