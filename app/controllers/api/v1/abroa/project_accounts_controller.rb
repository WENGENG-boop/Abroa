class Api::V1::Abroa::ProjectAccountsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create destroy]
  rescue_from ::Abroa::StudyProject::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    authorized = current_resource_owner.family.accounts.accessible_by(current_resource_owner).select(:id)
    page = ::Abroa::Page.fetch(project.project_accounts.where(account_id: authorized), limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |link| { account_id: link.account_id } }, meta: { next_cursor: page[:next_cursor] } })
  end

  def create
    fields = body_fields!(:account_id)
    raise ActiveRecord::RecordNotFound unless valid_uuid?(fields[:account_id])
    require_idempotency_key!
    link = ::Abroa::ProjectAccount.attach_for!(current_resource_owner, project.id, fields[:account_id])
    render_json({ data: { account_id: link.account_id } }, status: :created)
  end

  def destroy
    body_fields!
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:account_id])
    ::Abroa::ProjectAccount.detach_for!(current_resource_owner, project.id, params[:account_id])
    render_json({ data: { account_id: params[:account_id] } })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(current_resource_owner, params[:project_id])
    end
end
