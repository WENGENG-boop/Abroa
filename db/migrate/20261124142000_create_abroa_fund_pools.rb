class CreateAbroaFundPools < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_fund_pools, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects }
      t.references :goal, type: :uuid, index: false, foreign_key: true
      t.string :name, null: false
      t.string :kind, null: false
      t.string :currency, null: false
      t.decimal :target_amount, precision: 19, scale: 4
      t.string :status, null: false, default: "active"
      t.datetime :archived_at
      t.string :creation_key_digest
      t.string :creation_request_digest
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :project_id, :kind, :status ]
      t.index [ :goal_id ], unique: true, where: "goal_id IS NOT NULL"
      t.index [ :project_id, :creation_key_digest ], unique: true, where: "creation_key_digest IS NOT NULL",
        name: "idx_abroa_fund_creation_key"
    end
    add_check_constraint :abroa_fund_pools,
      "status IN ('active','archived') AND (target_amount IS NULL OR (target_amount >= 0 AND target_amount <> 'NaN'::numeric))",
      name: "abroa_fund_state_target"

    create_table :abroa_pool_movements, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :pool, type: :uuid, null: false, foreign_key: { to_table: :abroa_fund_pools }
      t.references :account, type: :uuid, null: false, foreign_key: true
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :entry_key
      t.uuid :fee_installment_id
      t.references :rate_snapshot, type: :uuid, foreign_key: { to_table: :abroa_rate_snapshots }
      t.references :reversal_of, type: :uuid, foreign_key: { to_table: :abroa_pool_movements }
      t.string :kind, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.decimal :reserved_released_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :currency, null: false
      t.string :operation_key, null: false
      t.string :request_digest, null: false
      t.timestamps
      t.index [ :family_id, :operation_key ], unique: true, name: "idx_abroa_pool_movement_key"
      t.index [ :pool_id, :account_id, :kind ]
      t.index [ :entry_key, :kind ]
      t.index [ :fee_installment_id, :kind ], name: "idx_abroa_pool_fee"
    end
    add_check_constraint :abroa_pool_movements,
      "kind IN ('allocate','release','reserve','unreserve','consume','refund') AND amount > 0 AND amount <> 'NaN'::numeric AND reserved_released_amount >= 0 AND reserved_released_amount <= amount AND reserved_released_amount <> 'NaN'::numeric",
      name: "abroa_pool_movement_safe"
  end
end
