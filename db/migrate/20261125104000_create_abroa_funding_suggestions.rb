class CreateAbroaFundingSuggestions < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_funding_suggestions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :funding_plan, type: :uuid, null: false,
        foreign_key: { to_table: :abroa_funding_plans, on_delete: :cascade }
      t.references :student_user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :resolved_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.integer :expected_version, null: false
      t.datetime :resolved_at
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :student_user_id, :creation_key_digest ], unique: true,
        name: "idx_abroa_funding_suggestion_idempotency"
      t.index [ :funding_plan_id, :status ]
    end
    add_check_constraint :abroa_funding_suggestions,
      "status IN ('pending','accepted','rejected','cancelled') AND expected_version >= 0",
      name: "abroa_funding_suggestion_state"
  end
end
