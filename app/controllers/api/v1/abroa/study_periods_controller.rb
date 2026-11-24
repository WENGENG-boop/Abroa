class Api::V1::Abroa::StudyPeriodsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update destroy]
  rescue_from ::Abroa::StudyProject::Conflict, ::Abroa::OperationRecord::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(periods, limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map { |period| period_payload(period) }, meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: period_payload(periods.find(params[:id])) })
  end

  def create
    fields = body_fields!(*::Abroa::StudyPeriod::FIELDS)
    record = ::Abroa::StudyPeriod.create_for!(Current.user, project.id, attributes: fields, key: require_idempotency_key!)
    render_json({ data: period_payload(record) }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::StudyPeriod::FIELDS, :lock_version)
    record = ::Abroa::StudyPeriod.change_for!(Current.user, project.id, params[:id],
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: period_payload(record) })
  end

  def destroy
    fields = body_fields!(:lock_version)
    record = ::Abroa::StudyPeriod.remove_for!(Current.user, project.id, params[:id], version: fields[:lock_version])
    render_json({ data: period_payload(record) })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:project_id])
      @project ||= ::Abroa::StudyProject.find_for!(Current.user, params[:project_id])
    end

    def periods
      project.periods
    end

    def period_payload(record)
      record.attributes.slice("id", "name", "kind", "start_on", "end_on", "parent_id", "lock_version")
    end
end
