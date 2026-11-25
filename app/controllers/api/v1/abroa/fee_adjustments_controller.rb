class Api::V1::Abroa::FeeAdjustmentsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create void]
  rescue_from ::Abroa::FeeAdjustment::Conflict, ::Abroa::FeePlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(fee.adjustments, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:kind, :amount, :reason, :installment_id)
    if fields[:installment_id].present? && !valid_uuid?(fields[:installment_id])
      raise ActiveRecord::RecordNotFound
    end
    adjustment = ::Abroa::FeeAdjustment.apply_for!(current_resource_owner, fee.id,
      kind: fields[:kind], amount: fields[:amount], reason: fields[:reason],
      installment_id: fields[:installment_id], key: require_idempotency_key!)
    render_json({ data: adjustment.payload }, status: :created)
  end

  def void
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    item = fee.adjustments.find(params[:id])
    record = ::Abroa::FeeAdjustment.void_for!(current_resource_owner, id: item.id)
    render_json({ data: record.payload })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(current_resource_owner, params[:project_id])
    end

    def fee
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:fee_id])
      @fee ||= project.fee_plans.find(params[:fee_id])
    end
end
