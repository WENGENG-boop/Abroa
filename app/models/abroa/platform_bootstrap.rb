class Abroa::PlatformBootstrap
  InvalidApproval = Class.new(StandardError)
  AlreadyInitialized = Class.new(StandardError)

  # This is intentionally NOT a web action, webhook or API endpoint.
  # A local operator must explicitly provide the existing Sure super admin UUID
  # and one-time human approval at a trusted deployment terminal.
  APPROVAL_PHRASE = "I_AUTHORIZE_FIRST_ABROA_PLATFORM_ADMIN".freeze

  def self.grant_initial_system_admin!(user_id:, approval:)
    raise InvalidApproval, "Explicit local bootstrap approval required" unless approval == APPROVAL_PHRASE
    raise InvalidApproval, "A UUID identity is required" unless
      user_id.to_s.match?(/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i)

    Abroa::PlatformRoleAssignment.transaction do
      ActiveRecord::Base.connection.execute(
        ActiveRecord::Base.sanitize_sql_array(
          [ "SELECT pg_advisory_xact_lock(?)", Abroa::PlatformAdministration::ROLE_LOCK_KEY ]
        )
      )
      actor = User.lock.find(user_id)
      raise InvalidApproval, "Only an active existing Sure super administrator can bootstrap" unless
        actor.active? && actor.super_admin?
      raise AlreadyInitialized, "A platform system administrator already exists" if
        Abroa::PlatformRoleAssignment.where(role: "system_admin").exists?

      assignment = Abroa::PlatformRoleAssignment.create!(
        user: actor, granted_by: actor, role: "system_admin"
      )
      Abroa::PlatformAuditEvent.create!(
        actor_user_id: actor.id, target_user_id: actor.id,
        action: "role_grant", outcome: "granted",
        request_id: SecureRandom.uuid, occurred_at: Time.current,
        safe_changes: { "role" => "system_admin", "method" => "one_time_local_bootstrap" }
      )
      assignment
    end
  end
end
