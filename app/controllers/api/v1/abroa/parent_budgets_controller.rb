class Api::V1::Abroa::ParentBudgetsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access
  rescue_from ::Abroa::BudgetNode::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def update
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    fields = body_fields!(:name, :limit_amount, :warning_threshold, :lock_version)
    record = ::Abroa::BudgetNode.parent_change_for!(current_resource_owner, params[:id],
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: record.payload })
  end
end
