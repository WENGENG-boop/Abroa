class Api::V1::Abroa::FundPoolsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update archive restore]
  rescue_from ::Abroa::FundPool::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(project.fund_pools, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |pool| pool.payload_for(current_resource_owner) },
      meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: pool.payload_for(current_resource_owner) })
  end

  def create
    fields = body_fields!(*::Abroa::FundPool::FIELDS)
    record = ::Abroa::FundPool.create_for!(current_resource_owner, project.id, attributes: fields,
      key: require_idempotency_key!)
    render_json({ data: record.payload_for(current_resource_owner) }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::FundPool::FIELDS, :lock_version)
    version = fields.delete(:lock_version)
    record = ::Abroa::FundPool.change_for!(current_resource_owner, pool.id, version: version, attributes: fields)
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def archive
    fields = body_fields!(:lock_version)
    record = ::Abroa::FundPool.archive_for!(current_resource_owner, pool.id, version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def restore
    fields = body_fields!(:lock_version)
    record = ::Abroa::FundPool.restore_for!(current_resource_owner, pool.id, version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def cash
    project
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:account_id])
    result = ::Abroa::AllocationGuard.summary_for!(current_resource_owner, params[:account_id])
    result = result.transform_values { |value| value.is_a?(BigDecimal) ? value.to_s("F") : value }
    render_json({ data: result })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(current_resource_owner, params[:project_id])
    end

    def pool
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @pool ||= project.fund_pools.find(params[:id])
    end
end
