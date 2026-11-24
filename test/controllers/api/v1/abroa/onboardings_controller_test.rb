require "test_helper"

class Api::V1::Abroa::OnboardingsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @write_key = ApiKey.create!(user: @user, name: "Onboarding write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Onboarding read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @profile = Abroa::Profile.change_for!(@user, version: 0, attributes: { parent_enabled: true })
  end

  test "read onboarding requires authentication and returns current step" do
    get "/api/v1/abroa/onboarding"
    assert_response :unauthorized
    get "/api/v1/abroa/onboarding", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "role", response.parsed_body.dig("data", "step")
  end

  test "steps require write scope and valid step" do
    patch "/api/v1/abroa/onboarding", params: { step: "review", lock_version: 1 }, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    patch "/api/v1/abroa/onboarding", params: { step: "invalid", lock_version: 1 }, as: :json, headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    patch "/api/v1/abroa/onboarding", params: { step: "review", lock_version: 1 }, as: :json, headers: api_headers(@write_key)
    assert_response :ok
    assert_equal "review", response.parsed_body.dig("data", "step")
  end

  test "completion requires idempotency key and write scope and replays the result" do
    path = "/api/v1/abroa/onboarding/complete"
    params = { lock_version: 1 }
    post path, params: params, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    post path, params: params, as: :json, headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    headers = api_headers(@write_key).merge("Idempotency-Key" => "finish-1")
    post path, params: params, as: :json, headers: headers
    assert_response :ok
    first = response.parsed_body.fetch("data")
    assert_equal "complete", first.fetch("step")
    post path, params: params, as: :json, headers: headers
    assert_response :ok
    assert_equal first, response.parsed_body.fetch("data")
    post path, params: { lock_version: 2 }, as: :json, headers: headers
    assert_response :conflict
  end
end
