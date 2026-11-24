class Api::V1::Abroa::ProjectsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, only: %i[create update archive restore]
  rescue_from ::Abroa::StudyProject::Conflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    page = ::Abroa::Page.fetch(::Abroa::StudyProject.for_user(Current.user), limit: params[:limit], cursor: params[:cursor])
    render_json({ data: page[:rows].map(&:payload), meta: { next_cursor: page[:next_cursor] } })
  end

  def show
    render_json({ data: project.payload })
  end

  def create
    fields = body_fields!(*::Abroa::StudyProject::FIELDS)
    record = ::Abroa::StudyProject.create_for!(Current.user,
      attributes: fields, key: require_idempotency_key!)
    render_json({ data: record.payload }, status: :created)
  end

  def update
    fields = body_fields!(*::Abroa::StudyProject::FIELDS, :status, :lock_version)
    record = ::Abroa::StudyProject.change_for!(Current.user, project.id,
      version: fields.delete(:lock_version), attributes: fields)
    render_json({ data: record.payload })
  end

  def archive
    fields = body_fields!(:lock_version)
    record = ::Abroa::StudyProject.archive_for!(Current.user, project.id, version: fields.fetch(:lock_version, nil))
    render_json({ data: record.payload })
  end

  def restore
    fields = body_fields!(:lock_version)
    record = ::Abroa::StudyProject.restore_for!(Current.user, project.id, version: fields.fetch(:lock_version, nil))
    render_json({ data: record.payload })
  end

  def summary
    fields = params.permit(:start_on, :end_on, :currency).to_h.symbolize_keys
    report = ::Abroa::ProjectSummary.for_user(Current.user, project.id, **fields)
    render_json({ data: report })
  end

  private
    def project
      raise ActiveRecord::RecordNotFound unless valid_uuid?(params[:id])
      @project ||= ::Abroa::StudyProject.find_for!(Current.user, params[:id])
    end
end
