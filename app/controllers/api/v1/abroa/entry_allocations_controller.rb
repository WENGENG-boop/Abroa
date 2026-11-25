class Api::V1::Abroa::EntryAllocationsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update destroy]
  rescue_from ::Abroa::StudyProject::Conflict, ::Abroa::OperationRecord::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(project.allocations.visible_to(current_resource_owner), limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: project.allocations.visible_to(current_resource_owner).find(params[:id]).payload })
  end

  def create
    fields = body_fields!(:entry_id, :amount, :currency, :category_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:entry_id])
    raise ActiveRecord::RecordNotFound if fields[:category_id].present? && !valid_uuid?(fields[:category_id])
    record = ::Abroa::EntryAllocation.allocate_for!(current_resource_owner, project.id, **fields, key: require_idempotency_key!)
    render_json({ data: record.payload }, status: :created)
  end

  def update
    fields = body_fields!(:lock_version, :amount, :category_id)
    raise ActiveRecord::RecordNotFound if fields[:category_id].present? && !valid_uuid?(fields[:category_id])
    category_id = fields.key?(:category_id) ? fields[:category_id] : :unchanged
    record = ::Abroa::EntryAllocation.change_for!(current_resource_owner, project.id, params[:id],
      version: fields[:lock_version], amount: fields[:amount], category_id: category_id)
    render_json({ data: record.payload })
  end

  def destroy
    fields = body_fields!(:lock_version)
    record = ::Abroa::EntryAllocation.remove_for!(current_resource_owner, project.id, params[:id], version: fields[:lock_version])
    render_json({ data: record.payload })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(current_resource_owner, params[:project_id])
    end
end
