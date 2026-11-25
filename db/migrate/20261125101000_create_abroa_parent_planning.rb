class CreateAbroaParentPlanning < ActiveRecord::Migration[8.1]
  def change
    add_column :abroa_grants, :resource_kind, :string, null: false, default: "project"
    add_column :abroa_grants, :resource_id, :uuid
    remove_index :abroa_grants, name: "idx_abroa_active_grant_capability"
    add_index :abroa_grants, [ :relationship_id, :project_id, :capability, :resource_kind, :resource_id ],
      unique: true, nulls_not_distinct: true, where: "status = 'active'", name: "idx_abroa_grants_scoped_active"
    add_check_constraint :abroa_grants,
      "(resource_kind = 'project' AND resource_id IS NULL) OR (resource_kind IN ('budget_node','fee_plan','fund_pool') AND resource_id IS NOT NULL)",
      name: "abroa_grant_exact_resource"

    create_table :abroa_planning_drafts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :parent_user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :title, null: false
      t.string :kind, null: false
      t.jsonb :payload, null: false, default: {}
      t.string :status, null: false, default: "draft"
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :parent_user_id, :creation_key_digest ], unique: true, name: "idx_abroa_draft_idempotency"
      t.index [ :parent_user_id, :status ]
    end
    add_check_constraint :abroa_planning_drafts,
      "kind IN ('budget','study_project') AND status IN ('draft','cancelled','submitted','accepted','rejected')",
      name: "abroa_draft_states"

    create_table :abroa_proposals, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :relationship, type: :uuid, null: false,
        foreign_key: { to_table: :abroa_relationships, on_delete: :cascade }
      t.references :project, type: :uuid, null: false,
        foreign_key: { to_table: :abroa_study_projects, on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :resolved_by, type: :uuid, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :planning_draft, type: :uuid, foreign_key: { to_table: :abroa_planning_drafts, on_delete: :nullify }
      t.string :operation, null: false
      t.uuid :target_id, null: false
      t.jsonb :payload, null: false, default: {}
      t.integer :expected_version, null: false
      t.string :status, null: false, default: "draft"
      t.datetime :expires_at, null: false
      t.datetime :resolved_at
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :actor_id, :creation_key_digest ], unique: true, name: "idx_abroa_proposal_idempotency"
      t.index [ :relationship_id, :status, :created_at ]
    end
    add_check_constraint :abroa_proposals, "operation IN ('budget_update')", name: "abroa_proposal_ops"
    add_check_constraint :abroa_proposals,
      "status IN ('draft','pending','accepted','rejected','cancelled','expired')",
      name: "abroa_proposal_states"
    add_check_constraint :abroa_proposals, "expected_version >= 0", name: "abroa_proposal_version"
  end
end
