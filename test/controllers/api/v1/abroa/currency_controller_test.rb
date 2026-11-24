require "test_helper"

class Api::V1::Abroa::CurrencyControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @key = ApiKey.create!(user: @user, name: "Currency write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Currency read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @source = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Source", currency: "CNY", balance: 20_000)
    @destination = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Destination", currency: "GBP", balance: 0)
    @date = Date.new(2025, 1, 10)
  end

  test "historical rates require authentication and distinguish missing rates" do
    path = "/api/v1/abroa/fx/rates"
    get path, params: { from: "USD", to: "GBP", date: @date.iso8601 }
    assert_response :unauthorized
    ExchangeRate.where(from_currency: "USD", to_currency: "GBP").delete_all
    get path, params: { from: "USD", to: "GBP", date: @date.iso8601, amount: "100" }, headers: api_headers(@read_key)
    assert_response :ok
    assert_equal true, response.parsed_body.dig("data", "incomplete")
    assert_nil response.parsed_body.dig("data", "converted_amount")
    ExchangeRate.create!(from_currency: "USD", to_currency: "GBP", date: @date, rate: BigDecimal("0.8"))
    get path, params: { from: "USD", to: "GBP", date: @date.iso8601, amount: "100" }, headers: api_headers(@read_key)
    assert_response :ok
    assert_equal BigDecimal("80"), BigDecimal(response.parsed_body.dig("data", "converted_amount"))
    get path, params: { from: "USD", to: "GBP", date: "yesterday" }, headers: api_headers(@read_key)
    assert_response :unprocessable_entity
  end

  test "region information does not claim bank connectivity" do
    get "/api/v1/abroa/regions/JP", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "JPY", response.parsed_body.dig("data", "currency")
    assert_equal [], response.parsed_body.dig("data", "connection_kinds")
    get "/api/v1/abroa/regions/ZZZ", headers: api_headers(@read_key)
    assert_response :unprocessable_entity
  end

  test "account profile updates require write scope and preserve balances" do
    path = "/api/v1/abroa/accounts/#{@source.id}/profile"
    assert_no_difference "Abroa::AccountProfile.count" do
      get path, headers: api_headers(@read_key)
      assert_response :ok
    end
    patch path, params: { country: "CN", wallet_kind: "alipay", lock_version: 0 }, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    patch path, params: { country: "CN", wallet_kind: "alipay", lock_version: 0 }, as: :json, headers: api_headers(@key)
    assert_response :ok
    assert_equal "alipay", response.parsed_body.dig("data", "wallet_kind")
    assert_equal BigDecimal("20000"), @source.reload.balance
    patch path, params: { country: "JP", lock_version: 0 }, as: :json, headers: api_headers(@key)
    assert_response :conflict
  end

  test "unrelated accounts cannot be accessed by profile endpoint" do
    outsider = users(:empty)
    account = Account.create!(family: outsider.family, owner: outsider, accountable: Depository.new,
      name: "Private", currency: "USD", balance: 100)
    path = "/api/v1/abroa/accounts/#{account.id}/profile"
    get path, headers: api_headers(@read_key)
    assert_response :not_found
    patch path, params: { country: "JP", lock_version: 0 }, as: :json, headers: api_headers(@key)
    assert_response :not_found
  end

  test "exchange API requires write permission and replays a single transaction" do
    path = "/api/v1/abroa/fx/exchanges"
    body = { source_account_id: @source.id, destination_account_id: @destination.id,
      date: Date.current.iso8601, debit_amount: "9000", credit_amount: "1000",
      fee_amount: "100", fee_currency: "CNY" }
    post path, params: body, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    post path, params: body, as: :json, headers: api_headers(@key)
    assert_response :unprocessable_entity

    headers = api_headers(@key).merge("Idempotency-Key" => "fx-test-1")
    assert_difference "Transfer.count", 1 do
      post path, params: body, as: :json, headers: headers
    end
    assert_response :created
    detail = response.parsed_body.fetch("data")
    assert_equal true, detail.fetch("consistent")
    assert_no_difference "Transfer.count" do
      post path, params: body, as: :json, headers: headers
      assert_response :created
      assert_equal detail.fetch("id"), response.parsed_body.dig("data", "id")
    end
    get "#{path}/#{detail.fetch('id')}", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal detail.fetch("id"), response.parsed_body.dig("data", "id")
  end

  test "invalid or other-tenant exchange id is not found" do
    get "/api/v1/abroa/fx/exchanges/not-a-uuid", headers: api_headers(@read_key)
    assert_response :not_found
    get "/api/v1/abroa/fx/exchanges/#{SecureRandom.uuid}", headers: api_headers(@read_key)
    assert_response :not_found
  end
end
