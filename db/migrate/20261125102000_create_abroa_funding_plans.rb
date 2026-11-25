class CreateAbroaFundingPlans < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :abroa_planning_drafts, name: "abroa_draft_states"
    add_check_constraint :abroa_planning_drafts,
      "kind IN ('budget','study_project','funding') AND status IN ('draft','cancelled','submitted','accepted','rejected')",
      name: "abroa_draft_states"

    create_table :abroa_funding_plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects, on_delete: :cascade }
      t.references :relationship, type: :uuid, null: false, foreign_key: { to_table: :abroa_relationships, on_delete: :cascade }
      t.references :student_user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :parent_user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :created_by, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :source_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :destination_account, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :nullify }
      t.references :fund_pool, type: :uuid, foreign_key: { to_table: :abroa_fund_pools, on_delete: :nullify }
      t.string :name, null: false
      t.string :kind, null: false, default: "living"
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :frequency, null: false
      t.date :scheduled_on, null: false
      t.date :ends_on
      t.string :status, null: false, default: "planned"
      t.datetime :confirmed_at
      t.datetime :cancelled_at
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :created_by_id, :creation_key_digest ], unique: true, name: "idx_abroa_funding_plan_create"
      t.index [ :student_user_id, :status ]
      t.index [ :parent_user_id, :status ]
      t.index [ :project_id, :status ]
    end
    add_check_constraint :abroa_funding_plans,
      "amount > 0 AND amount <> 'NaN'::numeric AND frequency IN ('once','weekly','monthly','quarterly','yearly')",
      name: "abroa_funding_plan_amount_frequency"
    add_check_constraint :abroa_funding_plans,
      "status IN ('planned','confirmed','partially_received','received','cancelled','rejected')",
      name: "abroa_funding_plan_state"
    add_check_constraint :abroa_funding_plans,
      "(frequency = 'once' AND ends_on IS NULL) OR (frequency <> 'once' AND ends_on IS NOT NULL AND ends_on >= scheduled_on)",
      name: "abroa_funding_plan_schedule"

    create_table :abroa_funding_receipts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :funding_plan, type: :uuid, null: false, foreign_key: { to_table: :abroa_funding_plans, on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :entry, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.references :rate_snapshot, type: :uuid, foreign_key: { to_table: :abroa_rate_snapshots, on_delete: :restrict }
      t.decimal :native_amount, precision: 19, scale: 4, null: false
      t.string :native_currency, null: false
      t.decimal :applied_amount, precision: 19, scale: 4, null: false
      t.date :entry_date, null: false
      t.date :due_on, null: false
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.timestamps
      t.index :entry_id, unique: true, name: "idx_abroa_funding_entry_once"
      t.index [ :funding_plan_id, :creation_key_digest ], unique: true, name: "idx_abroa_funding_match_idempotency"
    end
    add_check_constraint :abroa_funding_receipts,
      "native_amount > 0 AND native_amount <> 'NaN'::numeric AND applied_amount > 0 AND applied_amount <> 'NaN'::numeric",
      name: "abroa_funding_receipt_positive"

    create_table :abroa_funding_reversals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :funding_receipt, type: :uuid, null: false, foreign_key: { to_table: :abroa_funding_receipts, on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :entry, type: :uuid, null: false, foreign_key: { on_delete: :restrict }
      t.references :rate_snapshot, type: :uuid, foreign_key: { to_table: :abroa_rate_snapshots, on_delete: :restrict }
      t.decimal :native_amount, precision: 19, scale: 4, null: false
      t.string :native_currency, null: false
      t.decimal :applied_amount, precision: 19, scale: 4, null: false
      t.date :entry_date, null: false
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.timestamps
      t.index :entry_id, unique: true, name: "idx_abroa_funding_reversal_entry_once"
      t.index [ :funding_receipt_id, :creation_key_digest ], unique: true, name: "idx_abroa_funding_reversal_idempotency"
    end
    add_check_constraint :abroa_funding_reversals,
      "native_amount > 0 AND native_amount <> 'NaN'::numeric AND applied_amount > 0 AND applied_amount <> 'NaN'::numeric",
      name: "abroa_funding_reversal_positive"

    create_table :abroa_funding_notices, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :funding_plan, type: :uuid, null: false, foreign_key: { to_table: :abroa_funding_plans, on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :reported_on, null: false
      t.string :status, null: false, default: "active"
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :funding_plan_id, :creation_key_digest ], unique: true, name: "idx_abroa_funding_notice_idempotency"
    end
    add_check_constraint :abroa_funding_notices,
      "amount > 0 AND amount <> 'NaN'::numeric AND status IN ('active','revoked')",
      name: "abroa_funding_notice_valid"
  end
end
