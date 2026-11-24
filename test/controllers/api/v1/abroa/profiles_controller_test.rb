require "test_helper"

class Api::V1::Abroa::ProfilesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @write_key = ApiKey.create!(user: @user, name: "Abroa write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Abroa read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @other = users(:empty)
  end

  test "unauthenticated profile is rejected" do
    get "/api/v1/abroa/profile"
    assert_response :unauthorized
  end

  test "read returns defaults without writing a profile" do
    assert_no_difference "Abroa::Profile.count" do
      get "/api/v1/abroa/profile", headers: api_headers(@read_key)
    end
    assert_response :ok
    assert_equal "simple", response.parsed_body.dig("data", "mode")
  end

  test "write scope is required" do
    patch "/api/v1/abroa/profile", params: { mode: "custom", lock_version: 0 }, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
  end

  test "updates only the authenticated user's profile" do
    other_profile = Abroa::Profile.create!(user: @other, mode: "simple")
    patch "/api/v1/abroa/profile", params: {
      mode: "custom", student_enabled: true, lock_version: 0, user_id: @other.id, family_id: @other.family_id
    }, as: :json, headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    assert_equal "simple", other_profile.reload.mode
    assert_not Abroa::Profile.exists?(user: @user)

    patch "/api/v1/abroa/profile", params: { mode: "custom", student_enabled: true, lock_version: 0 },
      as: :json, headers: api_headers(@write_key)
    assert_response :ok
    assert_equal "custom", Abroa::Profile.find_by!(user: @user).mode
    assert_equal "simple", other_profile.reload.mode
    assert_equal 1, response.parsed_body.dig("data", "lock_version")
  end

  test "invalid preferences and invalid versions are rejected" do
    patch "/api/v1/abroa/profile", params: { mode: "bad", lock_version: 0 }, as: :json, headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    patch "/api/v1/abroa/profile", params: { mode: "custom", lock_version: "bad" }, as: :json, headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    patch "/api/v1/abroa/profile", params: { mode: "custom", lock_version: 0 }, as: :json, headers: api_headers(@write_key)
    assert_response :ok
    patch "/api/v1/abroa/profile", params: { mode: "simple", lock_version: 0 }, as: :json, headers: api_headers(@write_key)
    assert_response :conflict
  end
end
