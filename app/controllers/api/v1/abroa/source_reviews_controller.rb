class Api::V1::Abroa::SourceReviewsController < Api::V1::Abroa::BaseController
  before_action :ensure_write_access, except: :index
  rescue_from ::Abroa::SourceReview::Conflict, ::Abroa::SourceRecord::IdentityConflict, with: :render_conflict
  rescue_from ArgumentError, with: :render_invalid_input

  def index
    account_ids = Current.user.family.accounts.accessible_by(Current.user).select(:id)
    sources = ::Abroa::SourceRecord.where(family: Current.user.family, account_id: account_ids)
    visible_statements = Current.user.family.account_statements.where(account_id: account_ids).select(:id)
    sources = sources.where(statement_id: nil).or(sources.where(statement_id: visible_statements))
    scope = ::Abroa::SourceReview.where(family: Current.user.family, source_record_id: sources.select(:id))
    status = params[:status]
    if status.present?
      raise ArgumentError, "Unknown review status" unless %w[pending resolved dismissed].include?(status)
      scope = scope.where(status: status)
    end
    page = safe_page_param
    raise ArgumentError, "Page exceeds maximum" if page > 10_000
    items = scope.order(created_at: :desc, id: :desc).offset((page - 1) * 50).limit(51).to_a
    render_json({ data: items.first(50).map(&:payload), page: page, has_more: items.size > 50 })
  end

  def create
    fields = body_fields!(:source_record_id)
    require_uuid!(fields[:source_record_id])
    review = ::Abroa::SourceReview.open_for!(Current.user, fields[:source_record_id])
    render_json({ data: review.payload }, status: :created)
  end

  def assign_account
    require_uuid!(params[:id])
    fields = body_fields!(:account_id, :funding_kind, :expected_version)
    require_uuid!(fields[:account_id])
    review = ::Abroa::SourceReview.assign_account_for!(Current.user, review_id: params[:id],
      account_id: fields[:account_id], funding_kind: fields[:funding_kind], expected_version: fields[:expected_version])
    render_json({ data: review.payload })
  end

  def resolve
    require_uuid!(params[:id])
    fields = body_fields!(:resolution, :expected_version, :target_entry_id, :movement_kind)
    require_uuid!(fields[:target_entry_id]) if fields.key?(:target_entry_id) && fields[:target_entry_id].present?
    action = ::Abroa::SourceReview.resolve_for!(Current.user, review_id: params[:id],
      resolution: fields[:resolution], expected_version: fields[:expected_version],
      key: request.headers["Idempotency-Key"], target_entry_id: fields[:target_entry_id], movement_kind: fields[:movement_kind])
    render_json({ data: action.payload })
  end

  def reverse
    require_uuid!(params[:id])
    body_fields!
    action = ::Abroa::SourceReview.reverse_for!(Current.user, action_id: params[:id])
    render_json({ data: action.payload })
  end

  private
    def require_uuid!(value)
      raise ActiveRecord::RecordNotFound unless valid_uuid?(value)
    end
end
