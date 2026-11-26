require "test_helper"

class Api::V1::Abroa::PlatformUsersControllerTest < ActionDispatch::IntegrationTest
  setup do
    @system = users(:sure_support_staff)
    @operator = users(:empty)
    @target = users(:family_member)
    @outsider = users(:family_admin)
    @system_key = make_key(@system, "system")
    @operator_key = make_key(@operator, "operator")
    @outsider_key = make_key(@outsider, "outsider")
  end

  test "ordinary members and legacy Sure super admins cannot inherit platform access" do
    get "/api/v1/abroa/platform/users"
    assert_response :unauthorized
    get "/api/v1/abroa/platform/users", headers: api_headers(@system_key)
    assert_response :forbidden
    get "/api/v1/abroa/platform/users", headers: api_headers(@outsider_key)
    assert_response :forbidden
    assert_equal 0, Abroa::PlatformAuditEvent.count
  end

  test "platform operator receives bounded account metadata, never private financial data" do
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "operator")
    get "/api/v1/abroa/platform/users", params: { limit: 2 },
      headers: api_headers(@operator_key)
    assert_response :ok
    rows = response.parsed_body.fetch("data")
    assert_equal 2, rows.size
    assert rows.all? { |row| row.keys.sort == %w[created_at email id last_login_at platform_access_version role status] }
    assert_not_includes response.body, "balance"
    assert_not_includes response.body, "transaction"
    assert_not_includes response.body, "family_id"

    get "/api/v1/abroa/platform/users/#{@target.id}", headers: api_headers(@operator_key)
    assert_response :ok
    assert_equal @target.id, response.parsed_body.dig("data", "id")
    assert_not_includes response.body, "accounts"
  end

  test "only system roles can grant roles and access admins cannot escalate" do
    Abroa::PlatformRoleAssignment.create!(user: @system, role: "system_admin")
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "access_admin")
    post "/api/v1/abroa/platform/roles", as: :json,
      params: { user_id: @outsider.id, role: "system_admin" },
      headers: api_headers(@operator_key)
    assert_response :forbidden
    assert_not Abroa::PlatformRoleAssignment.exists?(user: @outsider)

    post "/api/v1/abroa/platform/roles", as: :json,
      params: { user_id: @outsider.id, role: "operator" },
      headers: api_headers(@system_key)
    assert_response :created
    assignment_id = response.parsed_body.dig("data", "id")
    assert_equal "operator", Abroa::PlatformRoleAssignment.find(assignment_id).role
    assert_equal "granted", Abroa::PlatformAuditEvent.order(:created_at).last.outcome

    delete "/api/v1/abroa/platform/roles/#{assignment_id}",
      headers: api_headers(@system_key)
    assert_response :ok
    assert_not Abroa::PlatformRoleAssignment.exists?(id: assignment_id)
  end

  test "suspension immediately invalidates API keys and sessions without purging ledger or user" do
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "access_admin")
    key = make_key(@target, "target")
    session = @target.sessions.create!
    initial_entries = Entry.count

    post "/api/v1/abroa/platform/users/#{@target.id}/suspend", as: :json,
      params: { platform_access_version: 0, reason_code: "abuse_prevention" },
      headers: api_headers(@operator_key)
    assert_response :ok
    assert_equal "suspended", response.parsed_body.dig("data", "status")
    assert_not @target.reload.active?
    assert @target.platform_suspended_at.present?
    assert_equal 0, @target.sessions.where(id: session.id).count
    assert key.reload.revoked_at.present?
    assert_equal initial_entries, Entry.count
    assert User.exists?(@target.id)

    get "/api/v1/abroa/profile", headers: api_headers(key)
    assert_response :unauthorized

    post "/api/v1/abroa/platform/users/#{@target.id}/unsuspend", as: :json,
      params: { platform_access_version: 1 }, headers: api_headers(@operator_key)
    assert_response :ok
    assert @target.reload.active?
    assert key.reload.revoked_at.present?
    assert_equal 2, @target.platform_access_version
    assert_equal 2, Abroa::PlatformAuditEvent.where(target_user_id: @target.id).count
  end

  test "stale suspend requests cannot alter state or create second success audit" do
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "access_admin")
    path = "/api/v1/abroa/platform/users/#{@target.id}/suspend"
    post path, as: :json,
      params: { platform_access_version: 0, reason_code: "abuse_prevention" },
      headers: api_headers(@operator_key)
    assert_response :ok
    post path, as: :json,
      params: { platform_access_version: 0, reason_code: "abuse_prevention" },
      headers: api_headers(@operator_key)
    assert_response :conflict
    assert_equal 1, @target.reload.platform_access_version
    assert_equal 1, Abroa::PlatformAuditEvent.where(outcome: "suspended").count
  end

  test "platform audit events are immutable and do not record secrets" do
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "access_admin")
    post "/api/v1/abroa/platform/users/#{@target.id}/suspend", as: :json,
      params: { platform_access_version: 0, reason_code: "abuse_prevention", secret: "sk-private-not-allowed" },
      headers: api_headers(@operator_key)
    assert_response :unprocessable_entity
    assert @target.reload.active?
    post "/api/v1/abroa/platform/users/#{@target.id}/suspend", as: :json,
      params: { platform_access_version: 0, reason_code: "abuse_prevention" },
      headers: api_headers(@operator_key)
    assert_response :ok
    event = Abroa::PlatformAuditEvent.order(:created_at).last
    assert_equal @operator.id, event.actor_user_id
    assert_equal @target.id, event.target_user_id
    assert event.request_id.present?
    assert_not_includes event.safe_changes.to_json, "sk-private"
    assert_raises(ActiveRecord::ReadOnlyRecord) { event.update!(outcome: "revoked") }
  end


  test "revoking a platform role immediately removes API access" do
    Abroa::PlatformRoleAssignment.create!(user: @system, role: "system_admin")
    operator_role = Abroa::PlatformRoleAssignment.create!(user: @operator, role: "operator")
    get "/api/v1/abroa/platform/users", headers: api_headers(@operator_key)
    assert_response :ok
    delete "/api/v1/abroa/platform/roles/#{operator_role.id}", headers: api_headers(@system_key)
    assert_response :ok
    get "/api/v1/abroa/platform/users", headers: api_headers(@operator_key)
    assert_response :forbidden
    assert_equal 0, Abroa::PlatformRoleAssignment.where(user: @operator).count
  end

  test "system administrator cannot suspend self or revoke the last system administrator" do
    role = Abroa::PlatformRoleAssignment.create!(user: @system, role: "system_admin")
    post "/api/v1/abroa/platform/users/#{@system.id}/suspend", as: :json,
      params: { platform_access_version: 0, reason_code: "compromised_account" },
      headers: api_headers(@system_key)
    assert_response :conflict
    assert @system.reload.active?
    delete "/api/v1/abroa/platform/roles/#{role.id}", headers: api_headers(@system_key)
    assert_response :conflict
    assert Abroa::PlatformRoleAssignment.exists?(id: role.id)
  end

  test "PostgreSQL prevents direct modifications of append only audit rows" do
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "access_admin")
    post "/api/v1/abroa/platform/users/#{@target.id}/suspend", as: :json,
      params: { platform_access_version: 0, reason_code: "policy_violation" },
      headers: api_headers(@operator_key)
    assert_response :ok
    event = Abroa::PlatformAuditEvent.last
    # db:test:prepare can restore a Ruby schema without SQL triggers; verify
    # the deploy-time repair hook before asserting the real PostgreSQL rule.
    assert Abroa::PlatformAuditEvent.ensure_storage_protected!
    assert_raises(ActiveRecord::StatementInvalid) do
      Abroa::PlatformAuditEvent.transaction(requires_new: true) do
        Abroa::PlatformAuditEvent.connection.execute(
          "UPDATE abroa_platform_audit_events SET outcome='revoked' WHERE id=" +
          Abroa::PlatformAuditEvent.connection.quote(event.id)
        )
      end
    end
    assert_equal "suspended", event.reload.outcome
  end

  test "rejected admin role escalation and stale account mutation are audit-only" do
    Abroa::PlatformRoleAssignment.create!(user: @system, role: "system_admin")
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "access_admin")
    target = @outsider

    assert_difference "Abroa::PlatformAuditEvent.where(outcome: 'denied').count", 1 do
      post "/api/v1/abroa/platform/roles", as: :json,
        params: { user_id: target.id, role: "system_admin", secret: "sk-audit-never" },
        headers: api_headers(@operator_key)
      assert_response :forbidden
    end
    assert_not Abroa::PlatformRoleAssignment.exists?(user: target)
    denied = Abroa::PlatformAuditEvent.order(:created_at).last
    assert_equal @operator.id, denied.actor_user_id
    assert_not_includes denied.safe_changes.to_json, "sk-audit-never"

    assert_difference "Abroa::PlatformAuditEvent.where(outcome: 'conflict').count", 1 do
      post "/api/v1/abroa/platform/users/#{@target.id}/suspend", as: :json,
        params: { platform_access_version: 999, reason_code: "abuse_prevention" },
        headers: api_headers(@operator_key)
      assert_response :conflict
    end
    assert @target.reload.active?
  end

  private

    def make_key(user, name)
      ApiKey.create!(user: user, name: "P5 #{name}",
        key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    end
end
