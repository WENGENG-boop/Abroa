class Api::V1::Abroa::PersonalDebtsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create cancel]
  rescue_from ::Abroa::PersonalDebt::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def index
    scope = ::Abroa::PersonalDebt.for_user(current_resource_owner)
    if params[:status].present?
      raise ArgumentError, "Invalid status" unless %w[open partially_settled settled cancelled].include?(params[:status])
      scope = scope.where(status: params[:status])
    end
    if params[:direction].present?
      raise ArgumentError, "Invalid direction" unless %w[receivable payable].include?(params[:direction])
      scope = scope.where(direction: params[:direction])
    end
    page = ::Abroa::Page.fetch(scope, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: debt.payload })
  end

  def create
    attrs = body_fields!(*::Abroa::PersonalDebt::FIELDS)
    record = ::Abroa::PersonalDebt.create_for!(current_resource_owner, attributes: attrs,
      key: require_idempotency_key!)
    render_json({ data: record.payload }, status: :created)
  end

  def cancel
    fields = body_fields!(:lock_version)
    debt.cancel_for!(current_resource_owner, version: fields[:lock_version])
    render_json({ data: debt.reload.payload })
  end

  private
    def debt
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @debt ||= ::Abroa::PersonalDebt.for_user(current_resource_owner).find(params[:id])
    end
end
