class Api::V1::Abroa::ReportsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create_export]
  rescue_from ::Abroa::ReportExport::Conflict, with: :render_conflict
  rescue_from ArgumentError, Date::Error, with: :render_invalid_input

  def show
    raw = request.query_parameters.symbolize_keys
    allowed = %i[scope project_id period_id start_on end_on currency account_ids]
    raise ArgumentError, "Unknown report filter" if (raw.keys - allowed).any?
    data = ::Abroa::FinancialReport.for_student!(current_resource_owner, **raw)
    render_json({ data: data })
  end

  def parent
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    raw = request.query_parameters.symbolize_keys
    raise ArgumentError, "Parent report supports only calendar month or study period" if
      (raw.keys - %i[month period_id]).any?
    data = ::Abroa::FinancialReport.for_parent!(current_resource_owner,
      project_id: params[:id], **raw)
    render_json({ data: data })
  end

  def create_export
    attrs = body_fields!(:scope, :project_id, :period_id, :start_on, :end_on,
      :month, :currency, :account_ids, :format)
    format = attrs.delete(:format)
    result = ::Abroa::ReportExport.create_for!(current_resource_owner,
      attributes: attrs, format: format, key: require_idempotency_key!)
    render_json({ data: result.payload }, status: :created)
  end

  def download
    raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
    result = ::Abroa::ReportExport.download_for!(current_resource_owner, params[:id])
    response.headers["Cache-Control"] = "no-store, private"
    response.headers["X-Content-Type-Options"] = "nosniff"
    response.headers["Content-Security-Policy"] = "sandbox"
    send_data(result[:content], type: result[:content_type],
      filename: result[:filename], disposition: "attachment")
  end
end
