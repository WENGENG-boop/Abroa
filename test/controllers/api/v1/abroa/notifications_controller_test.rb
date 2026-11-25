require "test_helper"

class Api::V1::Abroa::NotificationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @outsider = users(:empty)
    @student_key = ApiKey.create!(user: @student, name: "A12 API Key",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @student, name: "A12 readonly",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @other_key = ApiKey.create!(user: @outsider, name: "A12 other",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Notifications project", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-01-01" },
      key: "a12-api-project")
    @item = Abroa::InboxNotification.emit_for!(recipient: @student, event_kind: "budget_risk",
      source: @project, event_key: "a12-api-budget")
  end

  test "inbox lists only user's items, authenticated and tenant scoped" do
    get "/api/v1/abroa/notifications"
    assert_response :unauthorized
    get "/api/v1/abroa/notifications", headers: api_headers(@read_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal [ @item.id ], data.map { |item| item.fetch("id") }
    assert_equal "unread", data.first.fetch("state")
    assert_not_includes response.body, @project.name
    get "/api/v1/abroa/notifications", headers: api_headers(@other_key)
    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
  end

  test "only owner with write scope can mark a notification read" do
    path = "/api/v1/abroa/notifications/#{@item.id}/read"
    post path, headers: api_headers(@other_key)
    assert_response :not_found
    post path, headers: api_headers(@read_key)
    assert_response :forbidden
    post path, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "read", response.parsed_body.dig("data", "state")
    post path, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "read", @item.reload.state
  end

  test "preference version conflict and unknown options do not mutate" do
    path = "/api/v1/abroa/notification_preferences"
    get path, headers: api_headers(@read_key)
    assert_response :ok
    initial = response.parsed_body.fetch("data")
    assert_equal false, initial.fetch("email_enabled")
    patch path, params: { email_enabled: true, lock_version: initial.fetch("lock_version") },
      as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    patch path, params: { email_enabled: true, unknown: "x", lock_version: 0 },
      as: :json, headers: api_headers(@student_key)
    assert_response :unprocessable_entity
    patch path, params: { email_enabled: true, lock_version: initial.fetch("lock_version") },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal true, response.parsed_body.dig("data", "email_enabled")
    patch path, params: { email_enabled: false, lock_version: initial.fetch("lock_version") },
      as: :json, headers: api_headers(@student_key)
    assert_response :conflict
    assert_equal true, Abroa::NotificationPreference.for_user(@student).reload.email_enabled
    get path, headers: api_headers(@other_key)
    assert_response :ok
    assert_equal false, response.parsed_body.dig("data", "email_enabled")
  end
end
