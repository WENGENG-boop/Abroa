class Api::V1::Abroa::FundingNoticesController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create revoke]
  rescue_from ::Abroa::FundingNotice::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(plan.notices, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |notice| notice.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    raise ActiveRecord::RecordNotFound unless current_resource_owner.id == plan.parent_user_id
    fields = body_fields!(:amount, :reported_on)
    record = ::Abroa::FundingNotice.create_for!(current_resource_owner, plan.id,
      amount: fields[:amount], reported_on: fields[:reported_on], key: require_idempotency_key!)
    render_json({ data: record.payload_for(current_resource_owner) }, status: :created)
  end

  def revoke
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    fields = body_fields!(:lock_version)
    record = ::Abroa::FundingNotice.where(funding_plan_id: plan.id).find(params[:id])
    record = ::Abroa::FundingNotice.revoke_for!(current_resource_owner, record.id, version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  private
    def plan
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:funding_plan_id])
      @plan ||= ::Abroa::FundingPlan.for_actor(current_resource_owner).find(params[:funding_plan_id])
    end
end
