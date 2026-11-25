class Api::V1::Abroa::DebtSettlementsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create]
  rescue_from ::Abroa::DebtSettlement::Conflict, ::Abroa::PersonalDebt::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(debt.settlements,
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload),
      meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:kind, :entry_id, :amount, :refunded_settlement_id, :refund_link_id)
    if fields[:kind] == "source_refund"
      raise ArgumentError, "Unexpected cash fields" if fields.slice(:entry_id, :amount, :refunded_settlement_id).values.any?(&:present?)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:refund_link_id])
    else
      raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:entry_id])
      raise ArgumentError, "Unexpected refund link" if fields[:refund_link_id].present?
    end
    record = case fields[:kind]
    when "payment"
      raise ArgumentError, "Refund reference is forbidden for payment" if fields[:refunded_settlement_id].present?
      ::Abroa::DebtSettlement.settle_for!(current_resource_owner, debt.id,
        entry_id: fields[:entry_id], amount: fields[:amount], key: require_idempotency_key!)
    when "refund"
      raise ArgumentError, "Refund reference required" unless valid_uuid?(fields[:refunded_settlement_id])
      ::Abroa::DebtSettlement.refund_for!(current_resource_owner, debt.id,
        entry_id: fields[:entry_id], amount: fields[:amount],
        refunded_settlement_id: fields[:refunded_settlement_id], key: require_idempotency_key!)
    when "source_refund"
      ::Abroa::DebtSettlement.merchant_refund_for!(current_resource_owner, debt.id,
        refund_link_id: fields[:refund_link_id], key: require_idempotency_key!)
    else
      raise ArgumentError, "Expected payment, refund or source_refund kind"
    end
    render_json({ data: record.payload }, status: :created)
  end

  private
    def debt
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:personal_debt_id])
      @debt ||= ::Abroa::PersonalDebt.for_user(current_resource_owner).find(params[:personal_debt_id])
    end
end
