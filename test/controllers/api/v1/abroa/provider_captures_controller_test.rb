require "test_helper"

class Api::V1::Abroa::ProviderCapturesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Capture API", currency: "GBP", balance: 100)
    @account.entries.create!(entryable: Transaction.new, name: "Provider charge", amount: 10,
      currency: "GBP", date: Date.current, source: "simplefin", external_id: "api-bank-1")
    @key = ApiKey.create!(user: @user, name: "Capture write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Capture read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @path = "/api/v1/abroa/accounts/#{@account.id}/sources"
  end

  test "capture requires write scope and diagnoses without exposing secrets" do
    @account.syncs.create!(status: "failed", error: "secret access token")
    post "#{@path}/capture", params: { limit: 1 }, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    assert_no_difference "Entry.count" do
      assert_difference "Abroa::SourceRecord.count", 1 do
        post "#{@path}/capture", params: { limit: 1 }, as: :json, headers: api_headers(@key)
      end
      assert_response :ok
      assert_equal 1, response.parsed_body.dig("data", "captured_count")
      assert_no_difference "Abroa::SourceRecord.count" do
        post "#{@path}/capture", params: { limit: 1 }, as: :json, headers: api_headers(@key)
      end
    end
    get "#{@path}/diagnostics", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "unverified", response.parsed_body.dig("data", "live_connection_status")
    refute_includes response.body, "secret access token"
  end

  test "other tenant cannot access diagnostics or capture" do
    other = users(:empty)
    key = ApiKey.create!(user: other, name: "Other", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    get "#{@path}/diagnostics", headers: api_headers(key)
    assert_response :not_found
    post "#{@path}/capture", params: {}, as: :json, headers: api_headers(key)
    assert_response :not_found
  end
end
