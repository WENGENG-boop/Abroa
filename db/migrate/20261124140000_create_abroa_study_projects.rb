class CreateAbroaStudyProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_study_projects, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :owner, type: :uuid, null: false, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :name, null: false
      t.string :country, null: false
      t.string :origin_country
      t.string :city
      t.string :school
      t.string :timezone, null: false
      t.date :start_on, null: false
      t.date :end_on
      t.string :currency, null: false
      t.string :status, null: false, default: "planning"
      t.string :previous_status
      t.datetime :archived_at
      t.string :creation_key_digest, null: false
      t.string :creation_request_digest, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :owner_id, :creation_key_digest ], unique: true, name: "idx_abroa_project_create_key"
      t.index [ :owner_id, :status ]
    end
    add_check_constraint :abroa_study_projects, "end_on IS NULL OR end_on >= start_on", name: "abroa_project_dates"
    add_check_constraint :abroa_study_projects, "status IN ('planning','active','completed','archived')", name: "abroa_project_status"
    create_table :abroa_study_periods, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects, on_delete: :cascade }
      t.references :parent, type: :uuid, foreign_key: { to_table: :abroa_study_periods }
      t.string :kind, null: false
      t.string :name, null: false
      t.date :start_on, null: false
      t.date :end_on, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end
    add_check_constraint :abroa_study_periods, "end_on >= start_on AND (parent_id IS NULL OR parent_id <> id)", name: "abroa_period_dates_parent"
    create_table :abroa_project_accounts, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects, on_delete: :cascade }
      t.references :account, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.timestamps
      t.index [ :project_id, :account_id ], unique: true
    end
    create_table :abroa_entry_allocations, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :family, type: :uuid, null: false, foreign_key: { on_delete: :cascade }
      t.references :project, type: :uuid, null: false, foreign_key: { to_table: :abroa_study_projects, on_delete: :cascade }
      t.references :entry, type: :uuid, foreign_key: { on_delete: :nullify }
      t.uuid :entry_key, null: false
      t.references :category, type: :uuid, foreign_key: { on_delete: :nullify }
      t.decimal :amount, precision: 19, scale: 4, null: false
      t.string :currency, null: false
      t.date :entry_date, null: false
      t.string :direction, null: false
      t.integer :lock_version, null: false, default: 0
      t.timestamps
      t.index [ :project_id, :entry_key, :category_id ], unique: true, nulls_not_distinct: true, name: "idx_abroa_allocation_scope"
    end
    add_check_constraint :abroa_entry_allocations, "amount > 0 AND amount <> 'NaN'::numeric AND direction IN ('expense','income')", name: "abroa_allocation_positive"
  end
end
