class CreateAbroaStatementIntakes < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_statement_intakes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :statement, type: :uuid, null: false, index: { unique: true }, foreign_key: { to_table: :account_statements, on_delete: :cascade }
      t.references :account, type: :uuid, foreign_key: { on_delete: :nullify }
      t.references :actor, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :pdf_import, type: :uuid, foreign_key: { to_table: :imports, on_delete: :nullify }
      t.string :source_kind, null: false
      t.string :config_digest, null: false, limit: 64
      t.string :preview_digest, null: false, limit: 64
      t.string :file_digest, null: false, limit: 64
      t.jsonb :summary, null: false, default: {}
      t.timestamps
    end
  end
end
