class CreateAbroaFees < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_fee_plans, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects }
      t.references :budget_node, type: :uuid, foreign_key: { to_table: :abroa_budget_nodes }
      t.references :fund_pool, type: :uuid, foreign_key: { to_table: :abroa_fund_pools }
      t.references :recurring_transaction, type: :uuid, foreign_key: true
      t.references :category, type: :uuid, foreign_key: true
      t.string :name, null: false
      t.string :kind, null: false
      t.string :currency, null: false
      t.decimal :gross_amount, precision: 19, scale: 4, null: false
      t.decimal :discount_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :status, null: false, default: "active"
      t.integer :lock_version, null: false, default: 0
      t.string :creation_key_digest
      t.string :creation_request_digest
      t.timestamps
      t.index [ :project_id, :status, :kind ], name: "idx_abroa_fee_scope"
      t.index [ :project_id, :creation_key_digest ], unique: true,
        where: "creation_key_digest IS NOT NULL", name: "idx_abroa_fee_create_key"
    end
    add_check_constraint :abroa_fee_plans,
      "gross_amount >= 0 AND discount_amount >= 0 AND discount_amount <= gross_amount AND "       "gross_amount <> 'NaN'::numeric AND discount_amount <> 'NaN'::numeric AND status IN ('active','cancelled')",
      name: "abroa_fee_plan_valid"

    create_table :abroa_fee_installments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :fee_plan, type: :uuid, null: false, foreign_key: { to_table: :abroa_fee_plans }
      t.string :name, null: false
      t.date :due_on, null: false
      t.decimal :gross_amount, precision: 19, scale: 4, null: false
      t.decimal :discount_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :state, default: "confirmed", null: false
      t.integer :lock_version, null: false, default: 0
      t.string :creation_key_digest
      t.string :creation_request_digest
      t.timestamps
      t.index [ :fee_plan_id, :due_on ]
      t.index [ :fee_plan_id, :creation_key_digest ], unique: true,
        where: "creation_key_digest IS NOT NULL", name: "idx_abroa_installment_create_key"
    end
    add_check_constraint :abroa_fee_installments,
      "gross_amount >= 0 AND discount_amount >= 0 AND discount_amount <= gross_amount AND "       "gross_amount <> 'NaN'::numeric AND discount_amount <> 'NaN'::numeric AND state IN ('draft','confirmed','cancelled')",
      name: "abroa_installment_valid"

    create_table :abroa_fee_settlements, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :fee_installment, type: :uuid, null: false, foreign_key: { to_table: :abroa_fee_installments }
      t.references :allocation, type: :uuid, foreign_key: { to_table: :abroa_entry_allocations }
      t.references :refund_link, type: :uuid, foreign_key: { to_table: :abroa_refund_links }
      t.references :rate_snapshot, type: :uuid, foreign_key: { to_table: :abroa_rate_snapshots }
      t.string :kind, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.decimal :fee_amount, precision: 19, scale: 4, null: false
      t.string :fee_currency, null: false
      t.date :source_date, null: false
      t.string :operation_key, null: false
      t.string :request_digest, null: false
      t.timestamps
      t.index [ :family_id, :operation_key ], unique: true, name: "idx_abroa_settlement_key"
      t.index [ :allocation_id, :kind ], name: "idx_abroa_settlement_allocation"
      t.index [ :refund_link_id, :kind ], name: "idx_abroa_settlement_refund"
    end
    add_check_constraint :abroa_fee_settlements,
      "kind IN ('payment','refund') AND amount > 0 AND fee_amount > 0 AND "       "amount <> 'NaN'::numeric AND fee_amount <> 'NaN'::numeric AND "       "((kind = 'payment' AND allocation_id IS NOT NULL AND refund_link_id IS NULL) OR "       "(kind = 'refund' AND refund_link_id IS NOT NULL AND allocation_id IS NULL))",
      name: "abroa_settlement_source"
  end
end
