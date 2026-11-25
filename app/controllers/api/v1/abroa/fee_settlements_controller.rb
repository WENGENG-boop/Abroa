class Api::V1::Abroa::FeeSettlementsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create]
  rescue_from ::Abroa::FeePlan::Conflict, ::Abroa::FeeSettlement::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(installment.settlements.visible_to(current_resource_owner),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:kind, :allocation_id, :refund_link_id, :amount)
    key = require_idempotency_key!
    record = case fields[:kind]
    when "payment"
      raise ArgumentError, "Expected allocation_id only" if fields[:refund_link_id].present?
      ::Abroa::FeeSettlement.pay_for!(current_resource_owner, installment.id,
        allocation_id: fields[:allocation_id], amount: fields[:amount], key: key)
    when "refund"
      raise ArgumentError, "Expected refund_link_id only" if fields[:allocation_id].present?
      ::Abroa::FeeSettlement.refund_for!(current_resource_owner, installment.id,
        refund_link_id: fields[:refund_link_id], amount: fields[:amount], key: key)
    else
      raise ArgumentError, "Expected payment or refund"
    end
    render_json({ data: record.payload }, status: :created)
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

    def installment
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:installment_id])
      @installment ||= fee.installments.find(params[:installment_id])
    end
end
