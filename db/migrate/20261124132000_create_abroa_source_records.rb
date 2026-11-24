class CreateAbroaSourceRecords < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_source_records, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :import, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :statement, type: :uuid, foreign_key: { to_table: :account_statements, on_delete: :nullify }
      t.string :source_kind, null: false, limit: 32
      t.string :source_instance_key, null: false, limit: 128
      t.string :external_id, limit: 256
      t.string :source_row_key, null: false, limit: 192
      t.datetime :occurred_at
      t.date :local_date, null: false
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.string :direction, null: false
      t.string :status, null: false
      t.string :payment_channel
      t.string :raw_digest, null: false, limit: 64
      t.jsonb :normalized, null: false, default: {}
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :family_id, :source_kind, :source_instance_key, :external_id ],
        unique: true, where: "external_id IS NOT NULL", name: "idx_abroa_source_external"
      t.index [ :family_id, :source_kind, :source_instance_key, :source_row_key ],
        unique: true, name: "idx_abroa_source_first_row"
      t.index [ :family_id, :account_id, :local_date, :currency, :amount ], name: "idx_abroa_source_candidates"
      t.index [ :family_id, :status ], name: "idx_abroa_source_status"
    end
    add_check_constraint :abroa_source_records, "amount >= 0 AND amount <> 'NaN'::numeric", name: "abroa_source_amount_valid"
    add_check_constraint :abroa_source_records, "direction IN ('inflow', 'outflow', 'unknown')", name: "abroa_source_direction_valid"
    add_check_constraint :abroa_source_records, "status IN ('received', 'parsed', 'linked', 'posted', 'review', 'ignored', 'error', 'reversed', 'conflict')", name: "abroa_source_status_valid"
    add_check_constraint :abroa_source_records, "jsonb_typeof(normalized) = 'object'", name: "abroa_source_normalized_object"

    create_table :abroa_source_observations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_record, type: :uuid, null: false, foreign_key: { to_table: :abroa_source_records, on_delete: :cascade }
      t.references :import, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :statement, type: :uuid, foreign_key: { to_table: :account_statements, on_delete: :nullify }
      t.string :source_kind, null: false, limit: 32
      t.string :source_instance_key, null: false, limit: 128
      t.string :source_row_key, null: false, limit: 192
      t.string :raw_digest, null: false, limit: 64
      t.string :status, null: false
      t.jsonb :normalized, null: false, default: {}
      t.timestamps
      t.index [ :family_id, :source_kind, :source_instance_key, :source_row_key ],
        unique: true, name: "idx_abroa_observation_identity"
    end
    add_check_constraint :abroa_source_observations, "status IN ('observed', 'conflict')", name: "abroa_observation_status_valid"
  end
end
