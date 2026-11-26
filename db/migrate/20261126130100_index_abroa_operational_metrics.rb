class IndexAbroaOperationalMetrics < ActiveRecord::Migration[8.1]
  def change
    add_index :users, :created_at, if_not_exists: true,
      name: "idx_abroa_users_registered_at"
    add_index :users, :last_login_at, if_not_exists: true,
      name: "idx_abroa_users_activity_at"
    add_index :syncs, [ :syncable_type, :created_at, :status ], if_not_exists: true,
      name: "idx_abroa_syncs_operational_status"
    add_index :imports, [ :created_at, :status ], if_not_exists: true,
      name: "idx_abroa_imports_operational_status"
    add_index :abroa_ai_model_usages, [ :created_at, :status ], if_not_exists: true,
      name: "idx_abroa_ai_usage_operational_status"
  end
end
