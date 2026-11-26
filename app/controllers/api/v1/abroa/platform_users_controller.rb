class Api::V1::Abroa::PlatformUsersController < Api::V1::Abroa::BaseController
  before_action :require_platform_read!, only: %i[index show]
  before_action :require_platform_role_management!, only: %i[roles grant_role revoke_role]
  before_action :require_platform_suspension!, only: %i[suspend unsuspend]

  rescue_from Abroa::PlatformAdministration::Conflict, with: :platform_conflict
  rescue_from Abroa::PlatformAdministration::InvalidInput, with: :platform_invalid
  rescue_from Abroa::PlatformAdministration::Forbidden, with: :platform_forbidden

  def index
    allowed = %w[active suspended inactive]
    role = params[:role].presence
    status = params[:status].presence
    raise Abroa::PlatformAdministration::InvalidInput, "Invalid role filter" if role && !User.roles.key?(role)
    raise Abroa::PlatformAdministration::InvalidInput, "Invalid status filter" if status && !allowed.include?(status)

    limit = bounded_integer(params[:limit], fallback: 25, maximum: 100)
    page = bounded_integer(params[:page], fallback: 1, maximum: 1000)
    scope = User.order(created_at: :desc, id: :desc)
    scope = scope.where(role: role) if role
    scope = case status
    when "active" then scope.where(active: true, platform_suspended_at: nil)
    when "suspended" then scope.where.not(platform_suspended_at: nil)
    when "inactive" then scope.where(active: false)
    else scope
    end
    if params[:email].present?
      raise Abroa::PlatformAdministration::InvalidInput, "Invalid email filter" if params[:email].to_s.bytesize > 254
      scope = scope.where(email: params[:email].to_s.strip.downcase)
    end
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({
      data: rows.first(limit).map { |user| Abroa::PlatformAdministration.user_payload(user) },
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil }
    })
  end

  def show
    render_json({ data: Abroa::PlatformAdministration.user_payload(User.find(params[:id])) })
  end

  def roles
    limit = bounded_integer(params[:limit], fallback: 25, maximum: 100)
    page = bounded_integer(params[:page], fallback: 1, maximum: 1000)
    scope = Abroa::PlatformRoleAssignment.order(created_at: :desc, id: :desc)
    scope = scope.where(user_id: params[:user_id]) if params[:user_id].present?
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({
      data: rows.first(limit).map { |row| assignment_payload(row) },
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil }
    })
  end

  def grant_role
    return unless ensure_write_access
    body = body_fields!(:user_id, :role)
    target = User.find(body.fetch(:user_id))
    assignment = administration.grant_role!(target: target, role: body.fetch(:role).to_s)
    render_json({ data: assignment_payload(assignment) }, status: :created)
  end

  def revoke_role
    return unless ensure_write_access
    assignment = Abroa::PlatformRoleAssignment.find(params[:id])
    administration.revoke_role!(assignment: assignment)
    render_json({ data: { revoked: true, id: assignment.id } })
  end

  def suspend
    return unless ensure_write_access
    body = body_fields!(:platform_access_version, :reason_code)
    target = User.find(params[:id])
    target = administration.suspend!(
      target: target,
      version: strict_version(body.fetch(:platform_access_version, nil)),
      reason_code: body.fetch(:reason_code, nil).to_s
    )
    render_json({ data: Abroa::PlatformAdministration.user_payload(target) })
  end

  def unsuspend
    return unless ensure_write_access
    body = body_fields!(:platform_access_version)
    target = User.find(params[:id])
    target = administration.unsuspend!(
      target: target, version: strict_version(body.fetch(:platform_access_version, nil))
    )
    render_json({ data: Abroa::PlatformAdministration.user_payload(target) })
  end

  private

    # Sensitive failures are also append-only security events. Never persist
    # raw request bodies, passwords, emails, bank IDs or arbitrary user input.
    def audit_rejected_sensitive_operation(status:)
      return unless status.in?([ 403, 409 ]) && action_name.in?(%w[grant_role revoke_role suspend unsuspend])
      actor = current_resource_owner
      return unless actor&.persisted?

      action = {
        "grant_role" => "role_grant", "revoke_role" => "role_revoke",
        "suspend" => "user_suspend", "unsuspend" => "user_unsuspend"
      }.fetch(action_name)
      target_id = params[:id] || params[:user_id]
      target_id = nil unless target_id.to_s.match?(
        /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i
      )
      Abroa::PlatformAuditEvent.create!(
        actor_user_id: actor.id,
        target_user_id: target_id,
        action: action,
        outcome: status == 409 ? "conflict" : "denied",
        request_id: request.request_id,
        occurred_at: Time.current,
        safe_changes: { "result" => status }
      )
    end

    def administration
      @administration ||= Abroa::PlatformAdministration.new(
        actor: current_resource_owner, request_id: request.request_id
      )
    end

    def assignment_payload(row)
      { id: row.id, user_id: row.user_id, role: row.role, created_at: row.created_at }
    end

    def require_platform_read!
      require_platform_permission!("users.read")
    end

    def require_platform_role_management!
      require_platform_permission!("roles.manage")
    end

    def require_platform_suspension!
      require_platform_permission!("users.suspend")
    end

    def require_platform_permission!(permission)
      return if administration.permitted?(permission)

      audit_rejected_sensitive_operation(status: 403)
      render_json({ error: "forbidden", message: "Platform permission required" }, status: :forbidden)
    end

    def bounded_integer(raw, fallback:, maximum:)
      return fallback if raw.nil?
      value = Integer(raw.to_s, exception: false)
      raise Abroa::PlatformAdministration::InvalidInput, "Invalid page or limit" unless value && value.between?(1, maximum)
      value
    end

    def strict_version(raw)
      value = Integer(raw.to_s, exception: false)
      raise Abroa::PlatformAdministration::InvalidInput, "Invalid platform version" unless raw.is_a?(Integer) && value && value >= 0
      value
    end

    def platform_conflict(_error)
      audit_rejected_sensitive_operation(status: 409)
      render_json({ error: "conflict", message: "Account or permission version changed" }, status: :conflict)
    end

    def platform_invalid(error)
      render_json({ error: "validation_failed", message: error.message }, status: :unprocessable_entity)
    end

    def platform_forbidden(_error)
      audit_rejected_sensitive_operation(status: 403)
      render_json({ error: "forbidden", message: "Platform permission required" }, status: :forbidden)
    end
end
