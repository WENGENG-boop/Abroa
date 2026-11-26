class CreateAbroaOperationalManagement < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_operational_configs, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.string :category, null: false
      t.string :code, null: false
      t.jsonb :settings, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :category, :code ], unique: true, name: "idx_abroa_operational_config_unique"
    end
    add_check_constraint :abroa_operational_configs,
      "category IN ('bank_provider','ai_model','import_template','region','language','currency','channel','policy')",
      name: "abroa_operational_config_valid_category"

    # No FK to users: an erasure request MUST survive physical user deletion
    # without preserving the person's email or other personal information.
    create_table :abroa_governance_requests, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.uuid :user_id, null: false
      t.string :kind, null: false
      t.string :status, null: false, default: "requested"
      t.string :request_id, null: false
      t.datetime :requested_at, null: false
      t.datetime :reviewed_at
      t.datetime :completed_at
      t.uuid :reviewed_by_id
      t.string :reason_code
      t.uuid :evidence_export_id
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :user_id, :request_id ], unique: true, name: "idx_abroa_governance_user_request_dedupe"
      t.index [ :status, :requested_at ], name: "idx_abroa_governance_status_date"
      t.index [ :user_id, :created_at ], name: "idx_abroa_governance_user_date"
    end
    add_check_constraint :abroa_governance_requests,
      "kind IN ('export','deletion')",
      name: "abroa_governance_kind_valid"
    add_check_constraint :abroa_governance_requests,
      "status IN ('requested','approved','processing','completed','rejected','failed')",
      name: "abroa_governance_status_valid"
  end
end
