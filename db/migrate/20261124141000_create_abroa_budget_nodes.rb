class CreateAbroaBudgetNodes < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_budget_nodes, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects }
      t.references :parent, type: :uuid, foreign_key: { to_table: :abroa_budget_nodes }
      t.references :period, type: :uuid, foreign_key: { to_table: :abroa_study_periods }
      t.references :category, type: :uuid, foreign_key: true
      t.references :sure_budget, type: :uuid, foreign_key: { to_table: :budgets }
      t.string :name, null: false
      t.date :start_on, null: false
      t.date :end_on, null: false
      t.string :currency, null: false
      t.decimal :limit_amount, precision: 19, scale: 4, null: false
      t.boolean :rollover_enabled, default: false, null: false
      t.decimal :rollover_amount, precision: 19, scale: 4, default: 0, null: false
      t.references :rollover_target, type: :uuid, foreign_key: { to_table: :abroa_budget_nodes }
      t.string :status, default: "active", null: false
      t.decimal :warning_threshold, precision: 7, scale: 4, default: 0.8, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :project_id, :parent_id, :category_id, :start_on, :end_on ], unique: true,
        nulls_not_distinct: true, name: "idx_abroa_budget_scope"
    end
    add_check_constraint :abroa_budget_nodes, "end_on >= start_on AND limit_amount >= 0 AND limit_amount <> 'NaN'::numeric AND rollover_amount >= 0 AND rollover_amount <> 'NaN'::numeric", name: "abroa_budget_money_dates"
    add_check_constraint :abroa_budget_nodes, "status IN ('active','closed','archived') AND warning_threshold >= 0 AND warning_threshold <= 1 AND (parent_id IS NULL OR parent_id <> id)", name: "abroa_budget_lifecycle"
    create_table :abroa_budget_versions, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :budget_node, type: :uuid, null: false, foreign_key: { to_table: :abroa_budget_nodes }
      t.references :actor, type: :uuid, null: false, foreign_key: { to_table: :users }
      t.string :kind, null: false
      t.string :operation_key
      t.jsonb :from_data, default: {}, null: false
      t.jsonb :to_data, default: {}, null: false
      t.timestamps
      t.index [ :family_id, :operation_key ], unique: true, where: "operation_key IS NOT NULL",
        name: "idx_abroa_budget_operation"
    end
  end
end
