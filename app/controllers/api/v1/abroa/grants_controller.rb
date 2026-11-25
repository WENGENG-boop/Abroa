class Api::V1::Abroa::GrantsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create destroy]
  rescue_from ::Abroa::Grant::Conflict, ::Abroa::Relationship::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    scope = relationship.grants
    if current_resource_owner.id != relationship.student_user_id
      raise ActiveRecord::RecordNotFound unless relationship.status == "active"
      scope = scope.where(status: "active").where("expires_at IS NULL OR expires_at > ?", Time.current)
    end
    page = ::Abroa::Page.fetch(scope, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:project_id, :capability, :expires_at, :resource_kind, :resource_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:project_id])
    expiry = fields[:expires_at].present? ? Time.iso8601(fields[:expires_at]) : nil
    grant = ::Abroa::Grant.create_for!(current_resource_owner, relationship.id,
      project_id: fields.fetch(:project_id), capability: fields.fetch(:capability),
      resource_kind: fields.fetch(:resource_kind, "project"), resource_id: fields[:resource_id],
      expires_at: expiry, key: require_idempotency_key!)
    render_json({ data: grant.payload }, status: :created)
  end

  def destroy
    fields = body_fields!(:lock_version)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    grant = ::Abroa::Grant.revoke_for!(current_resource_owner, relationship.id, params[:id],
      version: fields.fetch(:lock_version, nil))
    render_json({ data: grant.payload })
  end

  private
    def relationship
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:relationship_id])
      @relationship ||= ::Abroa::Relationship.for_actor(current_resource_owner).find(params[:relationship_id])
    end
end
