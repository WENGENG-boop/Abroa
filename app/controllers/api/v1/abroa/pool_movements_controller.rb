class Api::V1::Abroa::PoolMovementsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create]
  rescue_from ::Abroa::FundPool::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    account_ids = current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    page = ::Abroa::Page.fetch(pool.movements.where(account_id: account_ids),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:account_id, :kind, :amount, :entry_id, :fee_installment_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:account_id])
    record = ::Abroa::PoolMovement.apply_for!(current_resource_owner, pool.id, **fields,
      key: require_idempotency_key!)
    render_json({ data: record.payload }, status: :created)
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(current_resource_owner, params[:project_id])
    end

    def pool
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:pool_id])
      @pool ||= project.fund_pools.find(params[:pool_id])
    end
end
