class CreateAbroaParentAccess < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_relationships, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :student_user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :parent_user, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :student_family, type: :uuid, null: false, foreign_key: { to_table: :families, on_delete: :cascade }
      t.references :parent_family, type: :uuid, null: false, foreign_key: { to_table: :families, on_delete: :cascade }
      t.string :status, null: false, default: "active"
      t.datetime :accepted_at, null: false
      t.datetime :revoked_at
      t.integer :version, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :student_user_id, :parent_user_id ], unique: true, where: "status = 'active'",
        name: "idx_abroa_unique_active_parent_pair"
      t.index [ :parent_user_id, :status ]
      t.index [ :student_user_id, :status ]
    end
    add_check_constraint :abroa_relationships,
      "student_user_id <> parent_user_id AND student_family_id <> parent_family_id AND family_id = student_family_id",
      name: "abroa_relation_tenant_bounds"
    add_check_constraint :abroa_relationships, "status IN ('active','revoked','expired')",
      name: "abroa_relation_states"

    create_table :abroa_relationship_invites, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :inviter, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.references :relationship, type: :uuid, foreign_key: { to_table: :abroa_relationships, on_delete: :nullify }
      t.string :inviter_role, null: false
      t.string :recipient_email_digest, null: false
      t.string :token_digest, null: false
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.string :status, null: false, default: "pending"
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index :token_digest, unique: true
      t.index [ :inviter_id, :creation_key_digest ], unique: true, name: "idx_abroa_invite_idempotency"
      t.index [ :inviter_id, :recipient_email_digest ], unique: true, where: "status = 'pending'",
        name: "idx_abroa_invite_active_pair"
      t.index :expires_at
    end
    add_check_constraint :abroa_relationship_invites, "status IN ('pending','accepted','rejected','revoked','expired')",
      name: "abroa_invite_states"
    add_check_constraint :abroa_relationship_invites, "inviter_role IN ('student','parent')",
      name: "abroa_invite_roles"

    create_table :abroa_grants, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :relationship, type: :uuid, null: false, foreign_key: { to_table: :abroa_relationships, on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects, on_delete: :cascade }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :capability, null: false
      t.string :status, null: false, default: "active"
      t.datetime :expires_at
      t.datetime :revoked_at
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :version, null: false, default: 1
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :relationship_id, :project_id, :capability ], unique: true, where: "status = 'active'",
        name: "idx_abroa_active_grant_capability"
      t.index [ :actor_id, :relationship_id, :creation_key_digest ], unique: true,
        name: "idx_abroa_grant_idempotency"
      t.index [ :project_id, :capability, :status ]
      t.index :expires_at
    end
    add_check_constraint :abroa_grants, "status IN ('active','revoked','expired')", name: "abroa_grant_states"
    add_check_constraint :abroa_grants,
      "capability IN ('summary','account_balance','transaction_details','budget_read','fees_read','forecasts_read','propose','budget_manage','fees_manage','pool_manage')",
      name: "abroa_grant_capabilities"
  end
end
