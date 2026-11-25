class Api::V1::Abroa::FundingPlansController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update confirm reject cancel]
  rescue_from ::Abroa::FundingPlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def index
    scope = ::Abroa::FundingPlan.for_actor(current_resource_owner)
    if params[:status].present?
      raise ArgumentError, "Invalid funding status" unless
        %w[planned confirmed partially_received received cancelled rejected].include?(params[:status])
      scope = scope.where(status: params[:status])
    end
    if params[:project_id].present?
      raise ArgumentError, "Invalid project ID" unless valid_uuid?(params[:project_id])
      scope = scope.where(project_id: params[:project_id])
    end
    page = ::Abroa::Page.fetch(scope, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |plan| plan.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: funding_plan.payload_for(current_resource_owner) })
  end

  def create
    fields = body_fields!(:relationship_id, :project_id, *::Abroa::FundingPlan::FIELDS)
    relation_id = fields.delete(:relationship_id)
    project_id = fields.delete(:project_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(relation_id) && valid_uuid?(project_id)
    plan = ::Abroa::FundingPlan.create_for!(current_resource_owner, relationship_id: relation_id,
      project_id: project_id, attributes: fields, key: require_idempotency_key!)
    render_json({ data: plan.payload_for(current_resource_owner) }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::FundingPlan::FIELDS, :lock_version)
    plan = ::Abroa::FundingPlan.change_for!(current_resource_owner, funding_plan.id,
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: plan.payload_for(current_resource_owner) })
  end

  def confirm
    fields = body_fields!(:lock_version, :destination_account_id, :fund_pool_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:destination_account_id])
    plan = ::Abroa::FundingPlan.confirm_for!(current_resource_owner, funding_plan.id,
      version: fields[:lock_version], destination_account_id: fields[:destination_account_id],
      fund_pool_id: fields[:fund_pool_id])
    render_json({ data: plan.payload_for(current_resource_owner) })
  end

  def reject
    fields = body_fields!(:lock_version)
    plan = ::Abroa::FundingPlan.reject_for!(current_resource_owner, funding_plan.id, version: fields[:lock_version])
    render_json({ data: plan.payload_for(current_resource_owner) })
  end

  def cancel
    fields = body_fields!(:lock_version)
    plan = ::Abroa::FundingPlan.cancel_for!(current_resource_owner, funding_plan.id, version: fields[:lock_version])
    render_json({ data: plan.payload_for(current_resource_owner) })
  end

  private
    def funding_plan
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @funding_plan ||= ::Abroa::FundingPlan.for_actor(current_resource_owner).find(params[:id])
    end
end
