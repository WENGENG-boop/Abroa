class Api::V1::Abroa::ProviderCapturesController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: :capture
  rescue_from ArgumentError, with: :render_invalid_input

  def capture
    fields = body_fields!(:limit, :after_id)
    result = ::Abroa::ProviderCapture.capture_for!(Current.user, account_id: account_id!, **fields)
    render_json({ data: result })
  end

  def diagnostics
    render_json({ data: ::Abroa::ProviderCapture.diagnostics_for!(Current.user, account_id: account_id!) })
  end

  private
    def account_id!
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:account_id])
      params[:account_id]
    end
end
