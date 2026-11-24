require "test_helper"

class Api::V1::Abroa::ProjectAccountsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @write = ApiKey.create!(user: @user, name: "account-links", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "account-links-read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Study accounts", country: "GB", timezone: "Europe/London", currency: "GBP",
      start_on: "2025-01-01", end_on: "2025-12-31" }, key: "account-controller")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Shared cash", currency: "GBP", balance: 1000)
    @path = "/api/v1/abroa/projects/#{@project.id}/accounts"
  end

  test "linking is explicit and visible to read scope without changing balances" do
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
    post @path, params: { account_id: @account.id }, as: :json,
      headers: api_headers(@read).merge("Idempotency-Key" => "link")
    assert_response :forbidden
    headers = api_headers(@write).merge("Idempotency-Key" => "link")
    post @path, params: { account_id: @account.id }, as: :json, headers: headers
    assert_response :created
    post @path, params: { account_id: @account.id }, as: :json, headers: headers
    assert_response :created
    assert_equal 1, @project.project_accounts.count
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ @account.id ], response.parsed_body.fetch("data").pluck("account_id")
    assert_equal 1000, @account.reload.balance
  end

  test "detaching does not remove account or original entry" do
    Abroa::ProjectAccount.attach_for!(@user, @project.id, @account.id)
    entry = @account.entries.create!(entryable: Transaction.new, name: "Purchase", amount: 25,
      currency: "GBP", date: Date.new(2025, 3, 1))
    delete "#{@path}/#{@account.id}", headers: api_headers(@write)
    assert_response :ok
    assert_equal 0, @project.project_accounts.count
    assert_equal BigDecimal("25"), entry.reload.amount
    assert_equal @account.id, Account.find(@account.id).id
  end
end
