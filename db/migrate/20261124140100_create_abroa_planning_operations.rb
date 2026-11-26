class CreateAbroaPlanningOperations < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_operation_records, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :operation, null: false
      t.string :key_digest, null: false
      t.string :request_digest, null: false
      t.string :resource_type, null: false
      t.uuid :resource_id, null: false
      t.timestamps
      t.index [ :actor_id, :operation, :key_digest ], unique: true, name: "idx_abroa_operation_replay"
    end

    create_table :abroa_planning_audit_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :actor, type: :uuid, null: true, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :event_type, null: false
      t.string :resource_type, null: false
      t.uuid :resource_id, null: false
      t.jsonb :safe_data, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
      t.index [ :family_id, :occurred_at ]
      t.index [ :resource_type, :resource_id, :occurred_at ], name: "idx_abroa_audit_resource"
    end
  end
end
