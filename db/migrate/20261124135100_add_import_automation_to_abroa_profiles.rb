class AddImportAutomationToAbroaProfiles < ActiveRecord::Migration[8.1]
  def change
    add_column :abroa_profiles, :import_automation, :string, null: false, default: "high_confidence"
    add_check_constraint :abroa_profiles, "import_automation IN ('manual', 'high_confidence')",
      name: "abroa_profile_import_automation"
  end
end
