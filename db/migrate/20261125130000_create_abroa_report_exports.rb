class CreateAbroaReportExports < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_report_exports, id: :uuid,
      default: -> { "gen_random_uuid()" } do |t|
      t.references :family, null: false, type: :uuid, foreign_key: { on_delete: :cascade }
      t.references :owner, null: false, type: :uuid, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :project, type: :uuid, foreign_key: { to_table: :abroa_study_projects, on_delete: :restrict }
      t.string :scope, null: false
      t.string :file_format, null: false
      t.string :status, default: "ready", null: false
      t.jsonb :filters, null: false, default: {}
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.string :grant_scope_digest
      t.string :sha256, null: false
      t.bigint :byte_size, null: false
      t.datetime :expires_at, null: false
      t.integer :lock_version, default: 0, null: false
      t.timestamps
      t.index [ :owner_id, :creation_key_digest ], unique: true, name: "idx_abroa_report_export_idempotency"
      t.index [ :owner_id, :created_at ]
    end
    add_check_constraint :abroa_report_exports,
      "scope IN ('personal','project','parent') AND file_format IN ('json','csv') AND " \
      "status IN ('ready','failed') AND byte_size BETWEEN 1 AND 2097152",
      name: "abroa_report_export_limits"
  end
end
