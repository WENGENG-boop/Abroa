class CreateAbroaFeeAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_fee_adjustments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :actor, null: false, type: :uuid, foreign_key: { to_table: :users }
      t.references :fee_plan, null: false, type: :uuid, foreign_key: { to_table: :abroa_fee_plans }
      t.references :fee_installment, type: :uuid, foreign_key: { to_table: :abroa_fee_installments }
      t.string :kind, null: false
      t.decimal :amount, null: false, precision: 19, scale: 4
      t.string :currency, null: false
      t.string :reason, null: false
      t.string :status, null: false, default: "approved"
      t.string :operation_key, null: false
      t.string :request_digest, null: false
      t.datetime :voided_at
      t.timestamps
      t.index [ :family_id, :operation_key ], unique: true, name: "idx_abroa_fee_adjustment_operation"
      t.index [ :fee_plan_id, :status, :kind ], name: "idx_abroa_fee_adjustment_totals"
    end
    add_check_constraint :abroa_fee_adjustments,
      "kind IN ('waiver','scholarship_offset','surcharge') AND status IN ('approved','void') AND amount > 0 AND amount <> 'NaN'::numeric",
      name: "abroa_fee_adjustment_valid"
  end
end
