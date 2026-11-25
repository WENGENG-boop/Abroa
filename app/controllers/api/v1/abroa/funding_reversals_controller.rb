class Api::V1::Abroa::FundingReversalsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: :create
  rescue_from ::Abroa::FundingReversal::Conflict, ::Abroa::FundingPlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(receipt.reversals, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |reversal| reversal.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:entry_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:entry_id])
    reversal = ::Abroa::FundingReversal.reverse_for!(current_resource_owner, receipt.id,
      entry_id: fields[:entry_id], key: require_idempotency_key!)
    render_json({ data: reversal.payload_for(current_resource_owner) }, status: :created)
  end

  private
    def receipt
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:funding_receipt_id])
      @receipt ||= ::Abroa::FundingReceipt.for_student(current_resource_owner).find(params[:funding_receipt_id])
    end
end
