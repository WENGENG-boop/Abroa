class Api::V1::Abroa::RelationshipInvitesController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create accept reject destroy]
  rescue_from ::Abroa::RelationshipInvite::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::RelationshipInvite.for_actor(current_resource_owner),
      limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    invite = ::Abroa::RelationshipInvite.for_actor(current_resource_owner).find(params[:id])
    render_json({ data: invite.payload })
  end

  def create
    fields = body_fields!(:recipient_email, :recipient_role)
    invite, token = ::Abroa::RelationshipInvite.issue_for!(current_resource_owner,
      recipient_email: fields.fetch(:recipient_email), recipient_role: fields.fetch(:recipient_role),
      key: require_idempotency_key!)
    render_json({ data: invite.payload.merge("invitation_token" => token) }, status: :created)
  end

  def accept
    fields = body_fields!(:token)
    relationship = ::Abroa::RelationshipInvite.accept_for!(current_resource_owner, token: fields.fetch(:token))
    render_json({ data: relationship.payload })
  end

  def reject
    fields = body_fields!(:token)
    invite = ::Abroa::RelationshipInvite.reject_for!(current_resource_owner, token: fields.fetch(:token))
    render_json({ data: invite.payload })
  end

  def destroy
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    invite = ::Abroa::RelationshipInvite.revoke_for!(current_resource_owner, id: params[:id])
    render_json({ data: invite.payload })
  end
end
