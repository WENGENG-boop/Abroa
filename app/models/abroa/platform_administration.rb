class Abroa::PlatformAdministration
  Conflict = Class.new(StandardError)
  InvalidInput = Class.new(StandardError)
  Forbidden = Class.new(StandardError)

  SUSPENSION_REASONS = %w[abuse_prevention compromised_account policy_violation user_request].freeze
  ROLE_LOCK_KEY = 8_391_249

  attr_reader :actor, :request_id

  def initialize(actor:, request_id:)
    @actor = actor
    @request_id = request_id
  end

  def permitted?(permission)
    Abroa::PlatformRoleAssignment.permitted?(actor, permission)
  end

  def require_permission!(permission)
    raise Forbidden unless permitted?(permission)
  end

  def grant_role!(target:, role:)
    require_permission!("roles.manage")
    raise InvalidInput, "Invalid platform role" unless Abroa::PlatformRoleAssignment::ROLES.include?(role)

    with_global_lock do
      target.lock!
      raise Conflict, "User is inactive" unless target.active?
      raise Conflict, "Role already assigned" if Abroa::PlatformRoleAssignment.exists?(user: target, role: role)

      assignment = Abroa::PlatformRoleAssignment.create!(
        user: target, granted_by: actor, role: role
      )
      audit!(action: "role_grant", outcome: "granted", target: target,
        changes: { role: role })
      assignment
    end
  end

  def revoke_role!(assignment:)
    require_permission!("roles.manage")
    with_global_lock do
      target = User.find(assignment.user_id)
      target.lock!
      assignment.reload
      if assignment.role == "system_admin" && last_platform_system_admin?(target)
        raise Conflict, "Cannot revoke last platform system admin"
      end

      role = assignment.role
      assignment.destroy!
      audit!(action: "role_revoke", outcome: "revoked", target: target,
        changes: { role: role })
    end
  end

  def suspend!(target:, version:, reason_code:)
    require_permission!("users.suspend")
    raise InvalidInput, "Invalid suspension reason" unless SUSPENSION_REASONS.include?(reason_code)
    change_status!(target: target, version: version, suspend: true, reason_code: reason_code)
  end

  def unsuspend!(target:, version:)
    require_permission!("users.suspend")
    change_status!(target: target, version: version, suspend: false)
  end

  def self.user_payload(user)
    status = if user.platform_suspended_at.present?
      "suspended"
    elsif user[:active]
      "active"
    else
      "inactive"
    end
    {
      id: user.id,
      email: user.email,
      role: user.role,
      status: status,
      created_at: user.created_at,
      last_login_at: user.last_login_at,
      platform_access_version: user.platform_access_version
    }
  end

  private

    def change_status!(target:, version:, suspend:, reason_code: nil)
      raise InvalidInput, "platform_access_version must be a nonnegative integer" unless version.is_a?(Integer) && version >= 0

      with_global_lock do
        target.lock!
        raise Conflict, "Resource version has changed" unless target.platform_access_version == version
        raise Conflict, "Cannot suspend own administrator account" if suspend && target.id == actor.id
        raise Conflict, "Invalid account status transition" unless suspend ? target.active? : target.platform_suspended_at.present?
        raise Conflict, "Account was deactivated" unless target[:active]
        if suspend && target.super_admin? && last_sure_super_admin?(target)
          raise Conflict, "Cannot suspend last Sure super administrator"
        end
        if suspend && last_platform_system_admin?(target)
          raise Conflict, "Cannot suspend last platform system administrator"
        end

        target.update!(
          platform_suspended_at: suspend ? Time.current : nil,
          platform_access_version: version + 1
        )
        if suspend
          # Reuse Sure's revocation primitive; do not change active=false
          # because that schedules UserPurgeJob and destroys financial history.
          target.sessions.destroy_all
          target.api_keys.active.update_all(revoked_at: Time.current)
          target.revoke_oauth_tokens!
        end
        outcome = suspend ? "suspended" : "unsuspended"
        audit!(action: suspend ? "user_suspend" : "user_unsuspend",
          outcome: outcome, target: target,
          changes: { from: suspend ? "active" : "suspended", to: outcome == "suspended" ? "suspended" : "active",
            version: version + 1, reason_code: reason_code }.compact)
        target
      end
    end

    def last_platform_system_admin?(user)
      return false unless Abroa::PlatformRoleAssignment.exists?(user: user, role: "system_admin")

      live_system_ids = Abroa::PlatformRoleAssignment.where(role: "system_admin").select(:user_id)
      User.where(id: live_system_ids, active: true, platform_suspended_at: nil)
        .where.not(id: user.id).none?
    end

    def last_sure_super_admin?(user)
      User.where(role: "super_admin", active: true, platform_suspended_at: nil)
        .where.not(id: user.id).none?
    end

    def with_global_lock
      ActiveRecord::Base.transaction do
        ActiveRecord::Base.connection.execute(
          ActiveRecord::Base.sanitize_sql_array([ "SELECT pg_advisory_xact_lock(?)", ROLE_LOCK_KEY ])
        )
        yield
      end
    end

    def audit!(action:, outcome:, target:, changes:)
      Abroa::PlatformAuditEvent.create!(
        actor_user_id: actor.id, target_user_id: target.id,
        action: action, outcome: outcome, request_id: request_id,
        occurred_at: Time.current, safe_changes: changes.stringify_keys
      )
    end
end
