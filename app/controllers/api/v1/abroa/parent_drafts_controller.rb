class Api::V1::Abroa::ParentDraftsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update destroy]
  rescue_from ::Abroa::PlanningDraft::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::PlanningDraft.for_user(current_resource_owner),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload_data), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: draft.payload_data })
  end

  def create
    record = ::Abroa::PlanningDraft.create_for!(current_resource_owner, attributes: body_fields!(*::Abroa::PlanningDraft::FIELDS),
      key: require_idempotency_key!)
    render_json({ data: record.payload_data }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::PlanningDraft::FIELDS, :lock_version)
    record = ::Abroa::PlanningDraft.change_for!(current_resource_owner, draft.id,
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: record.payload_data })
  end

  def destroy
    fields = body_fields!(:lock_version)
    record = ::Abroa::PlanningDraft.cancel_for!(current_resource_owner, draft.id, version: fields.fetch(:lock_version, nil))
    render_json({ data: record.payload_data })
  end

  private
    def draft
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @draft ||= ::Abroa::PlanningDraft.find_for!(current_resource_owner, params[:id])
    end
end
