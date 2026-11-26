class CreateAbroaPlatformAdministration < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :platform_suspended_at, :datetime
    add_column :users, :platform_access_version, :integer, null: false, default: 0
    add_index :users, :platform_suspended_at
    add_check_constraint :users, "platform_access_version >= 0", name: "users_platform_access_version_nonnegative"

    create_table :abroa_platform_role_assignments, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :granted_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :role, null: false
      t.timestamps
      t.index [ :user_id, :role ], unique: true, name: "idx_abroa_platform_role_unique"
    end
    add_check_constraint :abroa_platform_role_assignments,
      "role IN ('operator','access_admin','system_admin')", name: "abroa_platform_role_valid"

    create_table :abroa_platform_audit_events, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      # IDs intentionally outlive deleted users; never store emails or credentials here.
      t.uuid :actor_user_id
      t.uuid :target_user_id
      t.string :action, null: false
      t.string :outcome, null: false
      t.string :request_id, null: false
      t.jsonb :safe_changes, null: false, default: {}
      t.datetime :occurred_at, null: false
      t.timestamps
      t.index [ :target_user_id, :occurred_at ], name: "idx_abroa_platform_audit_target"
      t.index [ :actor_user_id, :occurred_at ], name: "idx_abroa_platform_audit_actor"
      t.index [ :request_id, :occurred_at ], name: "idx_abroa_platform_audit_request"
    end
  end
end
