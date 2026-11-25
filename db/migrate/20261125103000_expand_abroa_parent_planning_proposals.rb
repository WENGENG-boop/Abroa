class ExpandAbroaParentPlanningProposals < ActiveRecord::Migration[8.1]
  def change
    remove_check_constraint :abroa_proposals,
      "operation IN ('budget_update')", name: "abroa_proposal_ops"
    add_check_constraint :abroa_proposals,
      "operation IN ('budget_create','budget_update','study_project_update')",
      name: "abroa_proposal_ops"
    add_column :abroa_proposals, :applied_resource_id, :uuid
  end
end
