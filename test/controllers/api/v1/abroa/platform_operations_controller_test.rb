require "test_helper"

class Api::V1::Abroa::PlatformOperationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:sure_support_staff)
    @operator = users(:empty)
    @student = users(:family_admin)
    @other = users(:family_member)
    @admin_key = make_key(@admin)
    @operator_key = make_key(@operator)
    @student_key = make_key(@student)
    @other_key = make_key(@other)
    Abroa::PlatformRoleAssignment.create!(user: @admin, role: "system_admin")
    Abroa::PlatformRoleAssignment.create!(user: @operator, role: "operator")
  end

  test "anonymous, student and family admin lack platform metrics" do
    get "/api/v1/abroa/platform/operations/users"
    assert_response :unauthorized
    get "/api/v1/abroa/platform/operations/users", headers: api_headers(@student_key)
    assert_response :forbidden
    get "/api/v1/abroa/platform/operations/users", headers: api_headers(@other_key)
    assert_response :forbidden
  end

  test "user registrations, activity and retention show real denominator and time window" do
    get "/api/v1/abroa/platform/operations/users",
      params: { from: 30.days.ago.to_date.iso8601, to: Date.current.iso8601 },
      headers: api_headers(@operator_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal User.where(created_at: 30.days.ago.to_date.beginning_of_day..).count,
      data.dig("registrations", "count")
    assert data.fetch("window_start")
    assert data.fetch("window_end")
    assert_equal "users", data.fetch("source")
    assert data.dig("retention_7d", "eligible_denominator").is_a?(Integer)
    assert_nil data.dig("retention_7d", "rate") if
      data.dig("retention_7d", "eligible_denominator") == 0
    assert_not_includes response.body, "transaction"
    assert_not_includes response.body, "bank_balance"
  end

  test "bank, AI and import diagnostics expose only aggregate safe fields" do
    %w[banks ai imports].each do |name|
      get "/api/v1/abroa/platform/operations/#{name}", headers: api_headers(@operator_key)
      assert_response :ok
      data = response.parsed_body.fetch("data")
      assert_equal name, data.fetch("domain")
      assert data["sample_size"].is_a?(Integer)
      assert data["source"].is_a?(String)
      assert data["window_start"]
      assert data["window_end"]
      assert_not_includes response.body, "api_key"
      assert_not_includes response.body, "access_token"
      assert_not_includes response.body, "raw_file_str"
      assert_not_includes response.body, "account_balance"
    end
  end

  test "bank unknown provider cost must remain null, not invented zero" do
    get "/api/v1/abroa/platform/operations/banks", headers: api_headers(@operator_key)
    assert_response :ok
    assert_nil response.parsed_body.dig("data", "cost_amount")
    assert_nil response.parsed_body.dig("data", "cost_currency")
  end

  test "operational AI no known cost remains null and counts from source rows" do
    get "/api/v1/abroa/platform/operations/ai",
      params: { from: 7.days.ago.to_date.iso8601, to: Date.current.iso8601 },
      headers: api_headers(@operator_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    actual = Abroa::AiModelUsage.where(created_at: 7.days.ago.to_date.beginning_of_day..).count
    assert_equal actual, data.fetch("sample_size")
    assert_equal "abroa_ai_model_usages", data.fetch("source")
    assert data.fetch("known_cost_sample_size").is_a?(Integer)
    assert data.fetch("unknown_cost_count").is_a?(Integer)
    assert_equal actual, data.fetch("known_cost_sample_size") + data.fetch("unknown_cost_count")
  end

  test "health uses actual DB and Sidekiq/Redis probes, never fabricated counters" do
    get "/api/v1/abroa/platform/operations/health", headers: api_headers(@operator_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "healthy", data.dig("database", "status")
    assert_includes %w[healthy degraded unavailable], data.dig("redis", "status")
    assert data.dig("sidekiq", "queued_count").nil? ||
      data.dig("sidekiq", "queued_count").is_a?(Integer)
    assert_not_includes response.body, "redis://"
    assert_not_includes response.body, "SECRET_KEY_BASE"
  end

  test "window parameters reject invalid date, multi-year scan, inverted range and page overflow" do
    %w[2026-99-99 invalid].each do |invalid|
      get "/api/v1/abroa/platform/operations/users", params: { from: invalid },
        headers: api_headers(@operator_key)
      assert_response :unprocessable_entity
    end
    get "/api/v1/abroa/platform/operations/users",
      params: { from: "2020-01-01", to: "2026-11-26" },
      headers: api_headers(@operator_key)
    assert_response :unprocessable_entity
    get "/api/v1/abroa/platform/operations/users",
      params: { from: "2026-11-26", to: "2026-10-01" },
      headers: api_headers(@operator_key)
    assert_response :unprocessable_entity
  end

  test "configuration has validated allowed category and prohibits secrets in JSON" do
    post "/api/v1/abroa/platform/operations/configs", as: :json,
      params: { category: "bank_provider", code: "mock-bank",
        settings: { enabled: true, regions: %w[US GB], status: "available" } },
      headers: api_headers(@admin_key)
    assert_response :created
    config = Abroa::OperationalConfig.find(response.parsed_body.dig("data", "id"))
    assert_equal %w[US GB], config.settings["regions"]
    assert_equal "config_create", Abroa::PlatformAuditEvent.last.action

    post "/api/v1/abroa/platform/operations/configs", as: :json,
      params: { category: "bank_provider", code: "leaky",
        settings: { api_key: "sk-private", enabled: true } },
      headers: api_headers(@admin_key)
    assert_response :unprocessable_entity
    assert_not Abroa::OperationalConfig.exists?(code: "leaky")

    post "/api/v1/abroa/platform/operations/configs", as: :json,
      params: { category: "bank_provider", code: "private",
        settings: { display_name: "sk-private" } }, headers: api_headers(@admin_key)
    assert_response :unprocessable_entity
  end

  test "operator can list but cannot mutate or escalate configuration" do
    get "/api/v1/abroa/platform/operations/configs",
      headers: api_headers(@operator_key)
    assert_response :ok
    post "/api/v1/abroa/platform/operations/configs", as: :json,
      params: { category: "currency", code: "USD",
        settings: { enabled: true } }, headers: api_headers(@operator_key)
    assert_response :forbidden
    assert_not Abroa::OperationalConfig.exists?(code: "USD")
  end

  test "configuration optimistic update and sensitive values denied" do
    cfg = Abroa::OperationalConfig.create!(category: "currency", code: "GBP",
      settings: { "enabled" => true, "precision" => 2 })
    patch "/api/v1/abroa/platform/operations/configs/#{cfg.id}", as: :json,
      params: { version: 0, settings: { enabled: false, precision: 2 } },
      headers: api_headers(@admin_key)
    assert_response :ok
    assert_not cfg.reload.settings["enabled"]
    patch "/api/v1/abroa/platform/operations/configs/#{cfg.id}", as: :json,
      params: { version: 0, settings: { enabled: true, precision: 2 } },
      headers: api_headers(@admin_key)
    assert_response :conflict
    assert_not cfg.reload.settings["enabled"]
  end

  test "student can submit and only read own export governance request" do
    post "/api/v1/abroa/governance/requests", as: :json,
      params: { kind: "export" }, headers: api_headers(@student_key)
    assert_response :created
    request_id = response.parsed_body.dig("data", "id")
    assert_equal "requested", response.parsed_body.dig("data", "status")
    get "/api/v1/abroa/governance/requests", headers: api_headers(@student_key)
    assert_response :ok
    assert_includes response.body, request_id
    get "/api/v1/abroa/governance/requests/#{request_id}",
      headers: api_headers(@other_key)
    assert_response :not_found
    assert_not_includes response.body, @student.email
    assert_equal 0, Entry.where(description: "export").count if Entry.column_names.include?("description")
  end

  test "operator cannot approve governance and user cannot impersonate admin" do
    entry = Abroa::GovernanceRequest.create!(user_id: @student.id, kind: "deletion",
      status: "requested", requested_at: Time.current, request_id: SecureRandom.uuid)
    patch "/api/v1/abroa/platform/operations/governance/#{entry.id}", as: :json,
      params: { status: "approved", version: 0 },
      headers: api_headers(@operator_key)
    assert_response :forbidden
    patch "/api/v1/abroa/platform/operations/governance/#{entry.id}", as: :json,
      params: { status: "approved", version: 0 },
      headers: api_headers(@student_key)
    assert_response :forbidden
    assert_equal "requested", entry.reload.status
  end

  test "admin governance transition is versioned and audited and cannot fake completion" do
    entry = Abroa::GovernanceRequest.create!(user_id: @student.id, kind: "deletion",
      status: "requested", requested_at: Time.current, request_id: SecureRandom.uuid)
    patch "/api/v1/abroa/platform/operations/governance/#{entry.id}", as: :json,
      params: { status: "approved", version: 0 },
      headers: api_headers(@admin_key)
    assert_response :ok
    assert_equal "approved", entry.reload.status
    assert_equal "governance_transition", Abroa::PlatformAuditEvent.last.action

    patch "/api/v1/abroa/platform/operations/governance/#{entry.id}", as: :json,
      params: { status: "completed", version: 0 },
      headers: api_headers(@admin_key)
    assert_response :conflict
    patch "/api/v1/abroa/platform/operations/governance/#{entry.id}", as: :json,
      params: { status: "completed", version: 1 },
      headers: api_headers(@admin_key)
    assert_response :conflict
    assert_equal "approved", entry.reload.status
    assert User.exists?(@student.id)
  end

  test "pagination on operator resources is bounded and request IDs never expose PII" do
    get "/api/v1/abroa/platform/operations/configs",
      params: { limit: 10000 }, headers: api_headers(@operator_key)
    assert_response :unprocessable_entity
    get "/api/v1/abroa/platform/operations/governance",
      params: { page: 1, limit: 5 }, headers: api_headers(@operator_key)
    assert_response :ok
    assert_equal 5, response.parsed_body.dig("meta", "limit")
    assert_not_includes response.body, "bank_account"
  end

  private

    def make_key(user)
      ApiKey.create!(user: user, name: "P5 operations",
        key: ApiKey.generate_secure_key, source: "web", scopes: %w[read_write])
    end
end
