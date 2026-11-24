class Api::V1::Abroa::StatementReconciliationsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access
  rescue_from ::Abroa::StatementIntake::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def preview
    body_fields!
    render_json({ data: ::Abroa::StatementReconciliation.preview_for!(Current.user, statement_id: statement_id!) })
  end

  def confirm
    fields = body_fields!(:digest)
    render_json({ data: ::Abroa::StatementReconciliation.confirm_for!(Current.user,
      statement_id: statement_id!, digest: fields[:digest]) })
  end

  def undo
    body_fields!
    render_json({ data: ::Abroa::StatementReconciliation.undo_for!(Current.user, statement_id: statement_id!) })
  end

  private
    def statement_id!
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      params[:id]
    end
end
