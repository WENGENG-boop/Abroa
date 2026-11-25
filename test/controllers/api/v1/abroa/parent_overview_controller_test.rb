require "test_helper"

class Api::V1::Abroa::ParentOverviewControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @parent_key = ApiKey.create!(user: @parent, name: "Parent overview",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @outsider_key = ApiKey.create!(user: @outsider, name: "Outsider overview",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "overview-api")
    @relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "Parent accessible", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "overview-api-project")
    @hidden = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "Hidden project", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "overview-api-hidden")
    @budget = Abroa::BudgetNode.create_for!(@student, @project.id, attributes: {
      name: "Living", start_on: "2025-01-01", end_on: "2025-12-31",
      currency: "GBP", limit_amount: "1200"
    }, key: "overview-api-budget")
    @summary_grant = Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "summary", key: "api-summary")
  end

  test "parent project listing and summary are limited to summary grant" do
    get "/api/v1/abroa/parent/projects", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal [ @project.id ], response.parsed_body.fetch("data").pluck("id")
    get "/api/v1/abroa/parent/projects/#{@project.id}/summary", headers: api_headers(@parent_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "Parent accessible", data.dig("project", "name")
    assert_nil data["budgets"]
    assert_not_includes data.to_json, @budget.id
    assert_not_includes data.to_json, @hidden.id
    get "/api/v1/abroa/parent/projects/#{@hidden.id}/summary", headers: api_headers(@parent_key)
    assert_response :not_found
    get "/api/v1/abroa/parent/projects/#{@project.id}/summary", headers: api_headers(@outsider_key)
    assert_response :not_found
  end

  test "budget listing only with budget_read and summary grant" do
    path = "/api/v1/abroa/parent/projects/#{@project.id}/budgets"
    get path, headers: api_headers(@parent_key)
    assert_response :not_found
    grant = Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "budget_read", key: "api-budget-read")
    get path, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal [ @budget.id ], response.parsed_body.fetch("data").pluck("id")
    assert_not response.parsed_body.to_json.include?("sure_budget_id")
    Abroa::Grant.revoke_for!(@student, @relation.id, grant.id, version: grant.lock_version)
    get path, headers: api_headers(@parent_key)
    assert_response :not_found
    assert_equal BigDecimal("1200"), @budget.reload.limit_amount
  end

  test "fee pool expense and funding endpoints expose only separately authorized resources" do
    base = "/api/v1/abroa/parent/projects/#{@project.id}"
    fee = Abroa::FeePlan.create_for!(@student, @project.id,
      attributes: { name: "Tuition", kind: "tuition", currency: "GBP",
        gross_amount: "500", discount_amount: "50" }, key: "parent-fee-API")
    pool = Abroa::FundPool.create_for!(@student, @project.id,
      attributes: { name: "Student living", kind: "living", currency: "GBP",
        target_amount: "300" }, key: "parent-pool-API")
    account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Private student bank", currency: "GBP", balance: 1000)
    Abroa::ProjectAccount.attach_for!(@student, @project.id, account.id)
    entry = account.entries.create!(entryable: Transaction.new, name: "Private merchant",
      amount: 100, currency: "GBP", date: Date.new(2025, 3, 1))
    allocation = Abroa::EntryAllocation.allocate_for!(@student, @project.id,
      entry_id: entry.id, amount: "40", key: "parent-expense-api")
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: { name: "Family support", amount: "400",
        currency: "GBP", frequency: "once", scheduled_on: "2025-03-01" },
      key: "parent-allowed-plan")
    get "#{base}/fees", headers: api_headers(@parent_key)
    assert_response :not_found
    get "#{base}/pools", headers: api_headers(@parent_key)
    assert_response :not_found
    get "#{base}/expenses", headers: api_headers(@parent_key)
    assert_response :not_found
    get "#{base}/funding", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal [ plan.id ], response.parsed_body.fetch("data").pluck("id")

    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "fees_read", key: "parent-fee-read")
    get "#{base}/fees", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal [ fee.id ], response.parsed_body.fetch("data").pluck("id")
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "pool_manage", resource_kind: "fund_pool", resource_id: pool.id,
      key: "parent-pool-read")
    get "#{base}/pools", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal [ pool.id ], response.parsed_body.fetch("data").pluck("id")
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "transaction_details", key: "parent-expense-read")
    get "#{base}/expenses", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal [ allocation.id ], response.parsed_body.fetch("data").pluck("id")
    get "#{base}/fees", headers: api_headers(@outsider_key)
    assert_response :not_found

    Abroa::Grant.revoke_for!(@student, @relation.id, @summary_grant.id,
      version: @summary_grant.lock_version)
    %w[fees pools expenses funding].each do |endpoint|
      get "#{base}/#{endpoint}", headers: api_headers(@parent_key)
      assert_response :not_found
    end
  end

  test "revoked project summary immediately disables parent API access" do
    get "/api/v1/abroa/parent/projects/#{@project.id}/summary", headers: api_headers(@parent_key)
    assert_response :ok
    Abroa::Grant.revoke_for!(@student, @relation.id, @summary_grant.id,
      version: @summary_grant.lock_version)
    get "/api/v1/abroa/parent/projects/#{@project.id}/summary", headers: api_headers(@parent_key)
    assert_response :not_found
    get "/api/v1/abroa/parent/projects", headers: api_headers(@parent_key)
    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
  end
end
