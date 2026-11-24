class CreateAbroaSourceReviewsAndActions < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_source_reviews, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_record, type: :uuid, null: false, foreign_key: { to_table: :abroa_source_records, on_delete: :cascade }
      t.references :resolved_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :review_type, null: false, default: "source_resolution"
      t.string :reason_code, null: false
      t.jsonb :candidate_ids, null: false, default: []
      t.jsonb :evidence, null: false, default: {}
      t.string :status, null: false, default: "pending"
      t.datetime :resolved_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :family_id, :status ]
      t.index [ :source_record_id, :review_type ], unique: true, where: "status = 'pending'", name: "idx_abroa_open_source_review"
    end
    add_check_constraint :abroa_source_reviews, "status IN ('pending', 'resolved', 'dismissed')", name: "abroa_review_status"
    add_check_constraint :abroa_source_reviews, "(status = 'pending' AND resolved_at IS NULL) OR (status <> 'pending' AND resolved_at IS NOT NULL)", name: "abroa_review_resolution"

    create_table :abroa_source_actions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :source_record, type: :uuid, null: false, foreign_key: { to_table: :abroa_source_records, on_delete: :cascade }
      t.references :source_review, type: :uuid, null: false, index: { unique: true }, foreign_key: { to_table: :abroa_source_reviews, on_delete: :cascade }
      t.references :actor, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.string :operation, null: false
      t.string :operation_key, null: false, limit: 64
      t.string :request_digest, null: false, limit: 64
      t.jsonb :before_data, null: false, default: {}
      t.jsonb :after_data, null: false, default: {}
      t.datetime :reversed_at
      t.references :reversed_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
      t.index [ :family_id, :operation_key ], unique: true, name: "idx_abroa_source_action_key"
    end
    add_check_constraint :abroa_source_actions, "operation IN ('create', 'link', 'ignore', 'dismiss')", name: "abroa_source_action_operation"
  end
end
