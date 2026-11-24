class CreateAbroaRefundLinks < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_refund_links, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :original_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :nullify }
      t.references :refund_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :nullify }
      t.uuid :original_entry_key, null: false
      t.uuid :refund_entry_key, null: false
      t.references :rate_snapshot, type: :uuid, foreign_key: { to_table: :abroa_rate_snapshots, on_delete: :nullify }
      t.references :actor, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :revoked_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.decimal :applied_amount, precision: 19, scale: 4, null: false
      t.decimal :refund_amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :refund_currency, null: false
      t.date :original_date, null: false
      t.date :refund_date, null: false
      t.datetime :revoked_at
      t.timestamps
      t.index [ :family_id, :original_entry_key, :refund_entry_key ], unique: true, name: "idx_abroa_refund_pair"
    end
    add_check_constraint :abroa_refund_links, "applied_amount > 0 AND refund_amount > 0 AND applied_amount <> 'NaN'::numeric AND refund_amount <> 'NaN'::numeric", name: "abroa_refund_positive"
    add_check_constraint :abroa_refund_links, "original_entry_key <> refund_entry_key AND refund_date >= original_date", name: "abroa_refund_distinct_dates"
  end
end
