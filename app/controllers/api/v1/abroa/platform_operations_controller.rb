class Api::V1::Abroa::PlatformOperationsController < Api::V1::Abroa::BaseController
  before_action :require_operations_read!, only:
    %i[users banks ai imports health configs governance]
  before_action :require_operations_write!, only:
    %i[create_config update_config transition_governance]

  rescue_from Abroa::OperationalMetrics::InvalidWindow, with: :invalid_operations
  rescue_from Abroa::GovernanceRequest::Forbidden, with: :forbidden_operations
  rescue_from Abroa::GovernanceRequest::Conflict, with: :conflicting_operations
  rescue_from ActiveRecord::StaleObjectError, ActiveRecord::RecordNotUnique,
    with: :conflicting_operations
  rescue_from ArgumentError, with: :invalid_operations

  def users
    render_json({ data: window_metrics.users })
  end

  def banks
    render_json({ data: window_metrics.banks })
  end

  def ai
    render_json({ data: window_metrics.ai })
  end

  def imports
    render_json({ data: window_metrics.imports })
  end

  def health
    render_json({ data: Abroa::OperationalMetrics.health })
  end

  def configs
    page, limit = pagination
    category = params[:category].presence
    if category && !Abroa::OperationalConfig::CATEGORIES.include?(category)
      raise ArgumentError, "Unknown operational configuration category"
    end
    scope = Abroa::OperationalConfig.order(category: :asc, code: :asc, id: :asc)
    scope = scope.where(category: category) if category
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({
      data: rows.first(limit).map(&:payload),
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil,
        source: "abroa_operational_configs" }
    })
  end

  def create_config
    return unless ensure_write_access
    attrs = body_fields!(:category, :code, :settings)
    item = nil
    Abroa::OperationalConfig.transaction do
      item = Abroa::OperationalConfig.create!(attrs)
      audit!(action: "config_create", outcome: "created",
        changes: { "category" => item.category, "code" => item.code,
          "configured_fields" => item.settings.keys.sort })
    end
    render_json({ data: item.payload }, status: :created)
  end

  def update_config
    return unless ensure_write_access
    attrs = body_fields!(:version, :settings)
    version = strict_version(attrs.delete(:version))
    item = Abroa::OperationalConfig.find(params[:id])
    Abroa::OperationalConfig.transaction do
      item.lock!
      raise ActiveRecord::StaleObjectError.new(item, :update) unless item.lock_version == version

      item.update!(attrs)
      audit!(action: "config_update", outcome: "updated",
        changes: { "category" => item.category, "code" => item.code,
          "version" => item.lock_version, "configured_fields" => item.settings.keys.sort })
    end
    render_json({ data: item.payload })
  end

  def governance
    page, limit = pagination
    scope = Abroa::GovernanceRequest.order(requested_at: :desc, id: :desc)
    if params[:kind].present?
      raise ArgumentError, "Invalid governance kind" unless
        Abroa::GovernanceRequest::KINDS.include?(params[:kind])
      scope = scope.where(kind: params[:kind])
    end
    if params[:status].present?
      raise ArgumentError, "Invalid governance status" unless
        Abroa::GovernanceRequest::STATES.include?(params[:status])
      scope = scope.where(status: params[:status])
    end
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({
      data: rows.first(limit).map { |row| row.payload.merge(user_id: row.user_id) },
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil,
        source: "abroa_governance_requests" }
    })
  end

  def transition_governance
    return unless ensure_write_access
    attrs = body_fields!(:status, :version, :evidence_export_id, :reason_code)
    request_entry = Abroa::GovernanceRequest.find(params[:id])
    request_entry.transition!(
      actor: current_resource_owner, status: attrs[:status].to_s,
      version: strict_version(attrs[:version]),
      evidence_export_id: attrs[:evidence_export_id],
      reason_code: attrs[:reason_code]
    )
    render_json({ data: request_entry.payload })
  end

  def user_requests
    page, limit = pagination
    scope = Abroa::GovernanceRequest.where(user_id: current_resource_owner.id)
      .order(requested_at: :desc, id: :desc)
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({ data: rows.first(limit).map(&:payload),
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil } })
  end

  def user_request
    request_entry = Abroa::GovernanceRequest.where(user_id: current_resource_owner.id)
      .find(params[:id])
    render_json({ data: request_entry.payload })
  end

  def create_user_request
    return unless ensure_write_access
    fields = body_fields!(:kind)
    request_key = request.headers["Idempotency-Key"].presence || request.request_id
    request_entry = Abroa::GovernanceRequest.request_for!(
      user: current_resource_owner, kind: fields[:kind].to_s, request_id: request_key
    )
    render_json({ data: request_entry.payload }, status: :created)
  end

  private

    def window_metrics
      @window_metrics ||= Abroa::OperationalMetrics.new(from: params[:from], to: params[:to])
    end

    def pagination
      [ strict_page(params[:page], 1, 1000), strict_page(params[:limit], 25, 100) ]
    end

    def strict_page(value, fallback, maximum)
      return fallback if value.nil?
      number = Integer(value.to_s, exception: false)
      raise ArgumentError, "Invalid pagination parameter" unless
        number && number.between?(1, maximum)
      number
    end

    def strict_version(value)
      raise ArgumentError, "Invalid optimistic lock version" unless
        value.is_a?(Integer) && value >= 0
      value
    end

    def require_operations_read!
      require_operations_permission!("operations.read")
    end

    def require_operations_write!
      require_operations_permission!("operations.write")
    end

    def require_operations_permission!(permission)
      return if Abroa::PlatformRoleAssignment.permitted?(current_resource_owner, permission)
      render_json({ error: "forbidden",
        message: "Independent platform operations permission required" }, status: :forbidden)
    end

    def audit!(action:, outcome:, changes:)
      Abroa::PlatformAuditEvent.create!(
        actor_user_id: current_resource_owner.id,
        target_user_id: current_resource_owner.id,
        action: action, outcome: outcome, request_id: request.request_id,
        occurred_at: Time.current, safe_changes: changes
      )
    end

    def invalid_operations(_error)
      render_json({ error: "validation_failed",
        message: "Invalid operational configuration or parameter" }, status: :unprocessable_entity)
    end

    def conflicting_operations(_error)
      render_json({ error: "conflict",
        message: "A concurrent operation or invalid state transition prevented the change" },
        status: :conflict)
    end

    def forbidden_operations(_error)
      render_json({ error: "forbidden", message: "Access denied" }, status: :forbidden)
    end
end
