require "test_helper"

class Api::V1::Abroa::StudyPeriodsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @write = ApiKey.create!(user: @user, name: "period-write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "period-read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Study periods", country: "GB", timezone: "Europe/London", currency: "GBP",
      start_on: "2025-01-01", end_on: "2025-12-31" }, key: "periods-controller")
    @path = "/api/v1/abroa/projects/#{@project.id}/periods"
  end

  test "readers cannot create periods and repeated write keys do not duplicate" do
    fields = { name: "Term", kind: "term", start_on: "2025-01-01", end_on: "2025-03-31" }
    post @path, params: fields, as: :json, headers: api_headers(@read).merge("Idempotency-Key" => "term-key")
    assert_response :forbidden
    post @path, params: fields, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity
    headers = api_headers(@write).merge("Idempotency-Key" => "term-key")
    post @path, params: fields, as: :json, headers: headers
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    assert_no_difference "Abroa::StudyPeriod.count" do
      post @path, params: fields, as: :json, headers: headers
      assert_response :created
      assert_equal id, response.parsed_body.dig("data", "id")
    end
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
  end

  test "period update refuses stale versions and archive prevents writes" do
    period = Abroa::StudyPeriod.create_for!(@user, @project.id, attributes: {
      name: "Term", kind: "term", start_on: "2025-01-01", end_on: "2025-03-31" })
    patch "#{@path}/#{period.id}", params: { name: "Term revised", lock_version: 0 },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    patch "#{@path}/#{period.id}", params: { name: "Stale", lock_version: 0 },
      as: :json, headers: api_headers(@write)
    assert_response :conflict
    Abroa::StudyProject.archive_for!(@user, @project.id, version: @project.reload.lock_version)
    post @path, params: { name: "Forbidden", kind: "month", start_on: "2025-01-01", end_on: "2025-01-31" },
      as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "forbidden")
    assert_response :conflict
  end
end
