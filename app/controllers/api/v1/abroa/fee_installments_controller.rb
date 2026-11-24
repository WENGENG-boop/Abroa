class Api::V1::Abroa::FeeInstallmentsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update]
  rescue_from ::Abroa::FeePlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(fee.installments, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |period| period.payload_for(Current.user) }, meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: installment.payload_for(Current.user) })
  end

  def create
    fields = body_fields!(*::Abroa::FeeInstallment::FIELDS)
    record = ::Abroa::FeeInstallment.schedule_for!(Current.user, fee.id,
      attributes: fields, key: require_idempotency_key!)
    render_json({ data: record.payload_for(Current.user) }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::FeeInstallment::FIELDS, :lock_version)
    record = ::Abroa::FeeInstallment.change_for!(Current.user, installment.id,
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: record.payload_for(Current.user) })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(Current.user, params[:project_id])
    end

    def fee
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:fee_id])
      @fee ||= project.fee_plans.find(params[:fee_id])
    end

    def installment
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @installment ||= fee.installments.find(params[:id])
    end
end
