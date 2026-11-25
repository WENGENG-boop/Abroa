class Api::V1::Abroa::FeePlansController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update cancel import_recurring]
  rescue_from ::Abroa::FeePlan::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(project.fee_plans, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |plan| plan.payload_for(current_resource_owner) }, meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: fee.payload_for(current_resource_owner) })
  end

  def create
    fields = body_fields!(*::Abroa::FeePlan::FIELDS)
    record = ::Abroa::FeePlan.create_for!(current_resource_owner, project.id,
      attributes: fields, key: require_idempotency_key!)
    render_json({ data: record.payload_for(current_resource_owner) }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::FeePlan::FIELDS, :lock_version)
    record = ::Abroa::FeePlan.change_for!(current_resource_owner, fee.id,
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  def import_recurring
    fields = body_fields!(:from_on, :through_on)
    records = ::Abroa::FeeInstallment.import_recurring_for!(current_resource_owner, fee.id,
      from_on: fields[:from_on], through_on: fields[:through_on])
    render_json({ data: records.map { |record| record.payload_for(current_resource_owner) } })
  end

  def cancel
    fields = body_fields!(:lock_version)
    record = ::Abroa::FeePlan.cancel_for!(current_resource_owner, fee.id, version: fields[:lock_version])
    render_json({ data: record.payload_for(current_resource_owner) })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(current_resource_owner, params[:project_id])
    end

    def fee
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @fee ||= project.fee_plans.find(params[:id])
    end
end
