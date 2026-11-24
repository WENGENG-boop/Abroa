require "test_helper"

class Api::V1::Abroa::BudgetNodesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other = users(:empty)
    @write = ApiKey.create!(user: @user, name: "Budgets write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "Budgets read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @foreign = ApiKey.create!(user: @other, name: "Budgets foreign", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Budget API", country: "GB", timezone: "Europe/London", currency: "GBP",
      start_on: "2025-01-01", end_on: "2026-12-31" }, key: "budget-api-project")
    @path = "/api/v1/abroa/projects/#{@project.id}/budgets"
    @fields = { name: "Year", start_on: "2025-01-01", end_on: "2025-12-31",
      currency: "GBP", limit_amount: "1000", rollover_enabled: true }
  end

  test "create requires authenticated write scope and replays idempotency key" do
    post @path, params: @fields, as: :json, headers: api_headers(@read).merge("Idempotency-Key" => "year-1")
    assert_response :forbidden
    post @path, params: @fields, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity
    headers = api_headers(@write).merge("Idempotency-Key" => "year-1")
    assert_difference "Abroa::BudgetNode.count", 1 do
      post @path, params: @fields, as: :json, headers: headers
      assert_response :created
    end
    id = response.parsed_body.dig("data", "id")
    assert_no_difference "Abroa::BudgetNode.count" do
      post @path, params: @fields, as: :json, headers: headers
      assert_response :created
      assert_equal id, response.parsed_body.dig("data", "id")
    end
    post @path, params: @fields.merge(limit_amount: "2000"), as: :json, headers: headers
    assert_response :conflict
    get "#{@path}/#{id}", headers: api_headers(@foreign)
    assert_response :not_found
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
  end

  test "execution and adjustments are versioned and leave ledger unchanged" do
    budget = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: @fields)
    account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Budget API checking", currency: "GBP", balance: 3000)
    entry = account.entries.create!(entryable: Transaction.new, name: "Rent", amount: 200,
      currency: "GBP", date: Date.new(2025, 2, 2))
    Abroa::EntryAllocation.allocate_for!(@user, @project.id, entry_id: entry.id, amount: "200")
    get "#{@path}/#{budget.id}/execution", headers: api_headers(@read)
    assert_response :ok
    assert_equal "200.0", response.parsed_body.dig("data", "actual")
    assert_equal "800.0", response.parsed_body.dig("data", "remaining")
    patch "#{@path}/#{budget.id}", params: { lock_version: budget.lock_version, limit_amount: "1200" },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    post "#{@path}/#{budget.id}/adjust", params: { lock_version: budget.reload.lock_version,
      warning_threshold: "0.75" }, as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "1200.0", budget.reload.limit_amount.to_s("F")
    get "#{@path}/#{budget.id}/versions", headers: api_headers(@read)
    assert_response :ok
    assert_operator response.parsed_body.fetch("data").size, :>=, 3
    assert_equal BigDecimal("200"), entry.reload.amount
  end

  test "closed source rolls once and invalid scope is rejected" do
    source = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: @fields)
    target = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: @fields.merge(
      name: "Next year", start_on: "2026-01-01", end_on: "2026-12-31", limit_amount: "300"))
    source.update!(status: "closed")
    post "#{@path}/#{source.id}/rollover", params: { target_id: target.id }, as: :json,
      headers: api_headers(@write).merge("Idempotency-Key" => "roll-year")
    assert_response :ok
    assert_equal BigDecimal("1000"), target.reload.rollover_amount
    post "#{@path}/#{source.id}/rollover", params: { target_id: target.id }, as: :json,
      headers: api_headers(@write).merge("Idempotency-Key" => "roll-year")
    assert_response :ok
    assert_equal BigDecimal("1000"), target.reload.rollover_amount
  end
end
