require "test_helper"

class Api::V1::Abroa::ServiceEntitlementsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @system = users(:sure_support_staff)
    @student = users(:family_admin)
    @other = users(:empty)
    @system_key = new_key(@system, "system")
    @student_key = new_key(@student, "student")
    @other_key = new_key(@other, "other")
    Abroa::PlatformRoleAssignment.create!(user: @system, role: "system_admin")
    @plan = Abroa::ServicePlan.create!(code: "test-ai-package",
      name: "Test AI package", entitlements: { "ai_calls" => { "limit" => 2 } })
  end

  test "student entitlements and usage include only self and preserve unknown pricing" do
    get "/api/v1/abroa/commercial/entitlements", headers: api_headers(@student_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_includes data.fetch("always_free"), "core_finance"
    assert_nil data.dig("subscription", "plan")
    assert_nil data["cost_amount"]
    assert_nil data["cost_currency"]
    assert_not_includes response.body, "bank_balance"

    get "/api/v1/abroa/commercial/usage", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal [], response.parsed_body.fetch("data")
    assert_equal 1, response.parsed_body.dig("meta", "page")
  end

  test "missing credentials and unrelated user cannot read another subscription" do
    get "/api/v1/abroa/commercial/entitlements"
    assert_response :unauthorized
    subscription = Abroa::ServiceSubscription.assign!(
      user: @student, plan: @plan, status: "active", actor: @system
    )
    get "/api/v1/abroa/commercial/subscriptions/#{subscription.id}",
      headers: api_headers(@other_key)
    assert_response :forbidden
    assert_not_includes response.body, @student.email
  end

  test "non platform admin and operator cannot create or reprice plan" do
    post "/api/v1/abroa/commercial/plans", as: :json,
      params: { code: "other", name: "other", entitlements: {} },
      headers: api_headers(@student_key)
    assert_response :forbidden
    Abroa::PlatformRoleAssignment.create!(user: @other, role: "operator")
    post "/api/v1/abroa/commercial/plans", as: :json,
      params: { code: "other", name: "other", entitlements: {} },
      headers: api_headers(@other_key)
    assert_response :forbidden
    assert_not Abroa::ServicePlan.exists?(code: "other")
  end

  test "platform admin creates unpriced plan, validates feature limits and audits only safe data" do
    post "/api/v1/abroa/commercial/plans", as: :json,
      params: { code: "bank-extra", name: "Bank extra", entitlements:
        { bank_syncs: { limit: 4 } } },
      headers: api_headers(@system_key)
    assert_response :created
    data = response.parsed_body.fetch("data")
    assert_nil data["price_amount"]
    assert_nil data["price_currency"]
    assert_equal 4, data.dig("entitlements", "bank_syncs", "limit")
    assert_equal "plan_create", Abroa::PlatformAuditEvent.last.action

    post "/api/v1/abroa/commercial/plans", as: :json,
      params: { code: "invalid-core", name: "Core", entitlements:
        { core_finance: { limit: 1 } } },
      headers: api_headers(@system_key)
    assert_response :unprocessable_entity
    assert_not Abroa::ServicePlan.exists?(code: "invalid-core")
  end

  test "plan version concurrency and forbidden broad payloads" do
    patch "/api/v1/abroa/commercial/plans/#{@plan.id}", as: :json,
      params: { version: 0, enabled: false }, headers: api_headers(@system_key)
    assert_response :ok
    assert_not @plan.reload.enabled?
    patch "/api/v1/abroa/commercial/plans/#{@plan.id}", as: :json,
      params: { version: 0, enabled: true }, headers: api_headers(@system_key)
    assert_response :conflict
    assert_not @plan.reload.enabled?
    patch "/api/v1/abroa/commercial/plans/#{@plan.id}", as: :json,
      params: { version: 1, raw_payment_key: "sk-secret" },
      headers: api_headers(@system_key)
    assert_response :unprocessable_entity
    assert_not_includes Abroa::PlatformAuditEvent.last.safe_changes.to_json, "sk-secret"
  end

  test "admin assigns subscription with optimistic version and read only key cannot modify" do
    readonly = ApiKey.create!(user: @system, name: "read only", key: ApiKey.generate_secure_key,
      source: "web", scopes: %w[read])
    post "/api/v1/abroa/commercial/subscriptions/#{@student.id}", as: :json,
      params: { plan_id: @plan.id, status: "active" },
      headers: api_headers(readonly)
    assert_response :forbidden
    assert_equal 0, Abroa::ServiceSubscription.count

    post "/api/v1/abroa/commercial/subscriptions/#{@student.id}", as: :json,
      params: { plan_id: @plan.id, status: "active" },
      headers: api_headers(@system_key)
    assert_response :ok
    assert_equal "active", response.parsed_body.dig("data", "status")

    post "/api/v1/abroa/commercial/subscriptions/#{@student.id}", as: :json,
      params: { plan_id: @plan.id, status: "paused", version: 0 },
      headers: api_headers(@system_key)
    assert_response :ok
    assert_equal "paused", Abroa::ServiceSubscription.find_by!(user: @student).status
    post "/api/v1/abroa/commercial/subscriptions/#{@student.id}", as: :json,
      params: { plan_id: @plan.id, status: "active", version: 0 },
      headers: api_headers(@system_key)
    assert_response :conflict
    assert_equal "paused", Abroa::ServiceSubscription.find_by!(user: @student).status
  end

  test "admin simulated billing callback idempotent without ledger changes" do
    subscription = Abroa::ServiceSubscription.assign!(
      user: @student, plan: @plan, status: "active", actor: @system
    )
    count = Entry.count
    2.times do
      post "/api/v1/abroa/commercial/billing/simulate", as: :json,
        params: { user_id: @student.id, service_subscription_id: subscription.id,
          external_id: "callback-001", kind: "refund",
          occurred_at: "2026-11-26T11:00:00Z" },
        headers: api_headers(@system_key)
      assert_response :ok
    end
    assert_equal 1, Abroa::ServiceBillingEvent.count
    assert_equal count, Entry.count
    assert_nil Abroa::ServiceBillingEvent.last.amount
    assert_nil Abroa::ServiceBillingEvent.last.currency

    post "/api/v1/abroa/commercial/billing/simulate", as: :json,
      params: { user_id: @student.id, service_subscription_id: subscription.id,
        external_id: "callback-002", kind: "payment", amount: 0,
        currency: "USD", occurred_at: "2026-11-26T11:00:00Z" },
      headers: api_headers(@system_key)
    assert_response :unprocessable_entity
    assert_equal count, Entry.count
  end

  test "usage listing validates pagination, filter and prevents overflow" do
    get "/api/v1/abroa/commercial/usage", params: { page: -1 },
      headers: api_headers(@student_key)
    assert_response :unprocessable_entity
    get "/api/v1/abroa/commercial/usage", params: { feature: "core_finance" },
      headers: api_headers(@student_key)
    assert_response :unprocessable_entity
    get "/api/v1/abroa/commercial/usage", params: { limit: 10000 },
      headers: api_headers(@student_key)
    assert_response :unprocessable_entity
  end

  private

    def new_key(user, label)
      ApiKey.create!(user: user, name: "P5 #{label}", key: ApiKey.generate_secure_key,
        source: "web", scopes: %w[read_write])
    end
end
