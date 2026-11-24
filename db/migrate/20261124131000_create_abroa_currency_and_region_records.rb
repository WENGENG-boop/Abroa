class CreateAbroaCurrencyAndRegionRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_region_configs, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.string :country_code, null: false, limit: 2
      t.string :locale
      t.jsonb :defaults, null: false, default: {}
      t.boolean :enabled, null: false, default: true
      t.timestamps
      t.index :country_code, unique: true
    end

    create_table :abroa_account_profiles, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :account, type: :uuid, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :country, limit: 2
      t.string :wallet_kind
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :abroa_account_profiles, "wallet_kind IS NULL OR wallet_kind IN ('alipay', 'wechat', 'other')", name: "abroa_account_wallet_valid"

    create_table :abroa_rate_snapshots, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.string :from_currency, null: false
      t.string :to_currency, null: false
      t.decimal :rate, precision: 30, scale: 16, null: false
      t.date :rate_date, null: false
      t.date :as_of, null: false
      t.string :source, null: false
      t.string :source_reference
      t.string :quality, null: false
      t.timestamps
      t.index [ :family_id, :from_currency, :to_currency, :as_of ], name: "idx_abroa_rates_lookup"
    end
    add_check_constraint :abroa_rate_snapshots, "rate > 0 AND rate <> 'NaN'::numeric AND rate::text <> 'Infinity'", name: "abroa_snapshot_positive"
    add_check_constraint :abroa_rate_snapshots, "rate_date <= as_of AND quality IN ('exact', 'historical_fallback', 'parity')", name: "abroa_snapshot_date_quality"

    create_table :abroa_fx_details, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: true
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.references :transfer, type: :uuid, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.references :debit_entry, type: :uuid, null: false, foreign_key: { to_table: :entries, on_delete: :cascade }
      t.references :credit_entry, type: :uuid, null: false, foreign_key: { to_table: :entries, on_delete: :cascade }
      t.references :fee_entry, type: :uuid, foreign_key: { to_table: :entries, on_delete: :cascade }
      t.decimal :debit_amount, precision: 19, scale: 4, null: false
      t.decimal :credit_amount, precision: 19, scale: 4, null: false
      t.string :debit_currency, null: false
      t.string :credit_currency, null: false
      t.decimal :fee_amount, precision: 19, scale: 4, null: false, default: 0
      t.string :fee_currency
      t.decimal :actual_rate, precision: 30, scale: 16, null: false
      t.date :exchanged_on, null: false
      t.string :operation_key_digest, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.timestamps
      t.index [ :actor_id, :operation_key_digest ], unique: true, name: "idx_abroa_fx_actor_key"
    end
    add_check_constraint :abroa_fx_details, "debit_amount > 0 AND credit_amount > 0 AND actual_rate > 0 AND fee_amount >= 0 AND debit_currency <> credit_currency", name: "abroa_fx_amounts_valid"
    add_check_constraint :abroa_fx_details, "debit_amount <> 'NaN'::numeric AND credit_amount <> 'NaN'::numeric AND actual_rate <> 'NaN'::numeric AND fee_amount <> 'NaN'::numeric", name: "abroa_fx_finite_amounts"
    add_check_constraint :abroa_fx_details, "(fee_amount = 0 AND fee_entry_id IS NULL AND fee_currency IS NULL) OR (fee_amount > 0 AND fee_entry_id IS NOT NULL AND fee_currency IS NOT NULL AND fee_currency IN (debit_currency, credit_currency))", name: "abroa_fx_fee_valid"
  end
end
