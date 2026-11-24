require "test_helper"

class Api::V1::Abroa::FeeAdjustmentsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @foreign_user = users(:empty)
    @write = ApiKey.create!(user: @user, name: "adjust-write", key: ApiKey.generate_secure_key,
      scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "adjust-read", key: ApiKey.generate_secure_key,
      scopes: %w[read], source: "web")
    @foreign = ApiKey.create!(user: @foreign_user, name: "adjust-other",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Adjustment API", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "adjustment-api")
    @fee = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "Tuition", kind: "tuition", currency: "GBP", gross_amount: "1000",
      discount_amount: "0" }, key: "adjustment-fee")
    @path = "/api/v1/abroa/projects/#{@project.id}/fees/#{@fee.id}/adjustments"
  end

  test "scope check, idempotent scholarship, list and reversible adjustment" do
    fields = { kind: "scholarship_offset", amount: "100", reason: "Academic award" }
    post @path, params: fields, as: :json, headers: api_headers(@read).merge("Idempotency-Key" => "award")
    assert_response :forbidden
    post @path, params: fields, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity
    headers = api_headers(@write).merge("Idempotency-Key" => "award")
    assert_difference "Abroa::FeeAdjustment.count", 1 do
      post @path, params: fields, as: :json, headers: headers
      assert_response :created
    end
    id = response.parsed_body.dig("data", "id")
    assert_equal "900.0", @fee.reload.amount_due.to_s("F")
    assert_no_difference "Abroa::FeeAdjustment.count" do
      post @path, params: fields, as: :json, headers: headers
      assert_response :created
      assert_equal id, response.parsed_body.dig("data", "id")
    end
    post @path, params: fields.merge(amount: "300"), as: :json, headers: headers
    assert_response :conflict
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
    get @path, headers: api_headers(@foreign)
    assert_response :not_found
    post "#{@path}/#{id}/void", as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "void", response.parsed_body.dig("data", "status")
    assert_equal BigDecimal("1000"), @fee.reload.amount_due
  end
end
