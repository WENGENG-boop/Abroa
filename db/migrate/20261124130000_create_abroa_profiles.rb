class CreateAbroaProfiles < ActiveRecord::Migration[8.1]
  def change
    create_table :abroa_profiles, id: :uuid, default: -> { "gen_random_uuid()" } do |t|
      t.references :user, type: :uuid, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.boolean :student_enabled, null: false, default: false
      t.boolean :parent_enabled, null: false, default: false
      t.string :origin_country, limit: 2
      t.string :residence_country, limit: 2
      t.string :display_currency, limit: 12
      t.string :timezone, limit: 128
      t.string :mode, null: false, default: "simple"
      t.string :onboarding_step, null: false, default: "role"
      t.datetime :completed_at
      t.string :completion_key_digest, limit: 64
      t.integer :completion_request_version
      t.integer :completion_version
      t.integer :lock_version, null: false, default: 0
      t.timestamps
    end

    add_check_constraint :abroa_profiles, "mode IN ('simple', 'professional', 'custom')", name: "abroa_profiles_mode_valid"
    add_check_constraint :abroa_profiles, "onboarding_step IN ('role', 'region', 'preferences', 'review', 'complete')", name: "abroa_profiles_step_valid"
    add_check_constraint :abroa_profiles, "(onboarding_step = 'complete') = (completed_at IS NOT NULL)", name: "abroa_profiles_completion_valid"
    add_check_constraint :abroa_profiles, "completed_at IS NULL OR student_enabled OR parent_enabled", name: "abroa_profiles_completed_role_valid"
    add_check_constraint :abroa_profiles, "lock_version >= 0", name: "abroa_profiles_version_valid"
    add_check_constraint :abroa_profiles, "(completed_at IS NULL AND completion_key_digest IS NULL AND completion_request_version IS NULL AND completion_version IS NULL) OR (completed_at IS NOT NULL AND completion_key_digest IS NOT NULL AND completion_request_version IS NOT NULL AND completion_version IS NOT NULL)", name: "abroa_profiles_receipt_valid"
  end
end
