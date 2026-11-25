class Api::V1::Abroa::FundingSuggestionsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create accept reject cancel]
  rescue_from ::Abroa::FundingSuggestion::Conflict, ::Abroa::FundingPlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::FundingSuggestion.for_actor(current_resource_owner)
      .where(funding_plan_id: funding_plan.id), limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |suggestion| suggestion.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    raise ActiveRecord::RecordNotFound unless current_resource_owner.id == funding_plan.student_user_id
    fields = body_fields!(*::Abroa::FundingSuggestion::FIELDS)
    record = ::Abroa::FundingSuggestion.create_for!(current_resource_owner, funding_plan.id,
      attributes: fields, key: require_idempotency_key!)
    render_json({ data: record.payload_for(current_resource_owner) }, status: :created)
  end

  def accept
    fields = body_fields!(:lock_version)
    record = ::Abroa::FundingSuggestion.accept_for!(current_resource_owner, suggestion.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def reject
    fields = body_fields!(:lock_version)
    record = ::Abroa::FundingSuggestion.reject_for!(current_resource_owner, suggestion.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def cancel
    fields = body_fields!(:lock_version)
    record = ::Abroa::FundingSuggestion.cancel_for!(current_resource_owner, suggestion.id,
      version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  private
    def funding_plan
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:funding_plan_id])
      @funding_plan ||= ::Abroa::FundingPlan.for_actor(current_resource_owner).find(params[:funding_plan_id])
    end

    def suggestion
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @suggestion ||= ::Abroa::FundingSuggestion.for_actor(current_resource_owner)
        .where(funding_plan_id: funding_plan.id).find(params[:id])
    end
end
