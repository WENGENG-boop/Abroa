class Api::V1::Abroa::FundingReceiptsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: :create
  rescue_from ::Abroa::FundingReceipt::Conflict, ::Abroa::FundingPlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::FundingReceipt.where(funding_plan_id: plan.id),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |receipt| receipt.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    record = ::Abroa::FundingReceipt.where(funding_plan_id: plan.id).find(params[:id])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def create
    raise ActiveRecord::RecordNotFound unless current_resource_owner.id == plan.student_user_id
    fields = body_fields!(:entry_id, :due_on)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:entry_id])
    record = ::Abroa::FundingReceipt.match_for!(current_resource_owner, plan.id,
      entry_id: fields[:entry_id], due_on: fields[:due_on], key: require_idempotency_key!)
    render_json({ data: record.payload_for(current_resource_owner) }, status: :created)
  end

  private
    def plan
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:funding_plan_id])
      @plan ||= ::Abroa::FundingPlan.for_actor(current_resource_owner).find(params[:funding_plan_id])
    end
end
