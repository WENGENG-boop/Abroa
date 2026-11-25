class Api::V1::Abroa::RelationshipsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: :revoke
  rescue_from ::Abroa::Relationship::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::Relationship.for_actor(current_resource_owner),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: relationship.payload })
  end

  def revoke
    fields = body_fields!(:lock_version)
    record = ::Abroa::Relationship.revoke_for!(current_resource_owner, relationship.id,
      version: fields.fetch(:lock_version, nil))
    render_json({ data: record.payload })
  end

  private
    def relationship
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @relationship ||= ::Abroa::Relationship.for_actor(current_resource_owner).find(params[:id])
    end
end
