class CreateAbroaPersonalDebts < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_personal_debts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :owner, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :project, type: :uuid, foreign_key: { to_table: :abroa_study_projects, on_delete: :restrict }
      t.references :debt_account, null: false, type: :uuid, foreign_key: { to_table: :accounts, on_delete: :restrict }
      t.references :source_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :restrict }
      t.string :kind, null: false
      t.string :direction, null: false
      t.string :contact_nickname, null: false
      t.string :purpose
      t.string :currency, null: false
      t.decimal :personal_amount, precision: 19, scale: 4, default: 0, null: false
      t.decimal :other_amount, precision: 19, scale: 4, default: 0, null: false
      t.decimal :principal_amount, precision: 19, scale: 4, null: false
      t.decimal :source_amount, precision: 19, scale: 4
      t.string :source_currency
      t.date :source_date
      t.date :incurred_on, null: false
      t.date :due_on
      t.string :status, default: "open", null: false
      t.datetime :cancelled_at
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
      t.index [ :owner_id, :creation_key_digest ], unique: true, name: "idx_abroa_debt_idempotency"
      t.index :source_entry_id, unique: true, where: "source_entry_id IS NOT NULL", name: "idx_abroa_debt_unique_source"
      t.index [ :family_id, :status, :due_on ]
    end
    add_check_constraint :abroa_personal_debts,
      "kind IN ('paid_for_other','paid_by_other','lent','borrowed') AND " \
      "direction IN ('receivable','payable') AND " \
      "status IN ('open','partially_settled','settled','cancelled') AND " \
      "principal_amount > 0 AND personal_amount >= 0 AND other_amount >= 0 AND " \
      "principal_amount <> 'NaN'::numeric AND personal_amount <> 'NaN'::numeric AND other_amount <> 'NaN'::numeric",
      name: "abroa_debt_valid"

    create_table :abroa_debt_settlements, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :actor, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :personal_debt, null: false, type: :uuid, foreign_key: { to_table: :abroa_personal_debts, on_delete: :restrict }
      t.references :entry, null: false, type: :uuid, foreign_key: { to_table: :entries, on_delete: :restrict }
      t.references :rate_snapshot, type: :uuid, foreign_key: { to_table: :abroa_rate_snapshots, on_delete: :restrict }
      t.references :refunded_settlement, type: :uuid, foreign_key: { to_table: :abroa_debt_settlements, on_delete: :restrict }
      t.string :kind, default: "payment", null: false
      t.decimal :native_amount, precision: 19, scale: 4, null: false
      t.string :native_currency, null: false
      t.decimal :applied_amount, precision: 19, scale: 4, null: false
      t.date :entry_date, null: false
      t.decimal :entry_amount, precision: 19, scale: 4, null: false
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.timestamps
      t.index :entry_id, unique: true, name: "idx_abroa_debt_settlement_entry"
      t.index [ :personal_debt_id, :creation_key_digest ], unique: true, name: "idx_abroa_debt_settlement_idempotency"
    end
    add_check_constraint :abroa_debt_settlements,
      "kind IN ('payment','refund') AND native_amount > 0 AND applied_amount > 0 AND entry_amount > 0 AND " \
      "native_amount <> 'NaN'::numeric AND applied_amount <> 'NaN'::numeric AND entry_amount <> 'NaN'::numeric AND " \
      "((kind = 'payment' AND refunded_settlement_id IS NULL) OR (kind = 'refund' AND refunded_settlement_id IS NOT NULL))",
      name: "abroa_debt_settlement_valid"
  end
end
