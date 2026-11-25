require "test_helper"

class Api::V1::Abroa::ConsumptionControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Consumption API", currency: "GBP", balance: 100)
    @account.entries.create!(entryable: Transaction.new, name: "Expense", amount: 12.5,
      currency: "GBP", date: Date.new(2025, 1, 10))
    @key = ApiKey.create!(user: @user, name: "Consumption read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @path = "/api/v1/abroa/reports/consumption"
    @query = { start_on: "2025-01-01", end_on: "2025-01-31", currency: "GBP", account_ids: [ @account.id ] }
  end

  test "read key returns scoped report without ledger writes" do
    assert_no_difference [ "Entry.count", "Abroa::RateSnapshot.count" ] do
      get @path, params: @query, headers: api_headers(@key)
      assert_response :ok
      assert_equal "12.5", response.parsed_body.dig("data", "totals", "net_consumption")
      assert_equal [ @account.id ], response.parsed_body.dig("data", "account_ids")
      assert_equal false, response.parsed_body.dig("data", "incomplete")
    end
  end

  test "invalid query and foreign account are rejected" do
    get @path, params: @query
    assert_response :unauthorized
    get @path, params: @query.merge(start_on: "bad"), headers: api_headers(@key)
    assert_response :unprocessable_entity
    other = users(:empty)
    foreign = Account.create!(family: other.family, owner: other, accountable: Depository.new,
      name: "Foreign", currency: "GBP", balance: 100)
    get @path, params: @query.merge(account_ids: [ foreign.id ]), headers: api_headers(@key)
    assert_response :not_found
  end
end
