require "test_helper"

class Api::V1::Abroa::FeesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @other = users(:empty)
    @write = ApiKey.create!(user: @user, name: "fees-write", key: ApiKey.generate_secure_key,
      scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "fees-read", key: ApiKey.generate_secure_key,
      scopes: %w[read], source: "web")
    @foreign = ApiKey.create!(user: @other, name: "fees-foreign", key: ApiKey.generate_secure_key,
      scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fee API school", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2026-12-31" }, key: "fee-api-project")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Fee cash", currency: "GBP", balance: 10_000)
    @path = "/api/v1/abroa/projects/#{@project.id}/fees"
    @fields = { name: "First year tuition", kind: "tuition", currency: "GBP",
      gross_amount: "5000", discount_amount: "500" }
  end

  test "only owners with write scope create fees and idempotency replay is stable" do
    post @path, params: @fields, as: :json, headers: api_headers(@read).merge("Idempotency-Key" => "fee-a")
    assert_response :forbidden
    post @path, params: @fields, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity
    headers = api_headers(@write).merge("Idempotency-Key" => "fee-a")
    assert_difference "Abroa::FeePlan.count", 1 do
      post @path, params: @fields, as: :json, headers: headers
      assert_response :created
    end
    id = response.parsed_body.dig("data", "id")
    assert_equal "4500.0", response.parsed_body.dig("data", "amount_due")
    assert_no_difference "Abroa::FeePlan.count" do
      post @path, params: @fields, as: :json, headers: headers
      assert_response :created
      assert_equal id, response.parsed_body.dig("data", "id")
    end
    post @path, params: @fields.merge(discount_amount: "1000"), as: :json, headers: headers
    assert_response :conflict
    get "#{@path}/#{id}", headers: api_headers(@foreign)
    assert_response :not_found
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
  end

  test "installment create and confirmed transaction settlement work through scoped APIs" do
    plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: @fields, key: "fee-api")
    base = "#{@path}/#{plan.id}/installments"
    schedule = { name: "Autumn", gross_amount: "5000", discount_amount: "500", due_on: "2025-09-01" }
    post base, params: schedule, as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "autumn")
    assert_response :created
    installment_id = response.parsed_body.dig("data", "id")
    assert_equal "4500.0", response.parsed_body.dig("data", "net_amount")
    entry = @account.entries.create!(entryable: Transaction.new,
      name: "First tuition", amount: 2000, currency: "GBP", date: Date.new(2025, 8, 10))
    allocation = Abroa::EntryAllocation.allocate_for!(@user, @project.id,
      entry_id: entry.id, amount: "2000", key: "fee-api-ledger")
    payment_path = "#{base}/#{installment_id}/settlements"
    headers = api_headers(@write).merge("Idempotency-Key" => "autumn-payment")
    assert_no_difference "Entry.count" do
      post payment_path, params: { kind: "payment", allocation_id: allocation.id, amount: "2000" },
        as: :json, headers: headers
      assert_response :created
    end
    first_id = response.parsed_body.dig("data", "id")
    post payment_path, params: { kind: "payment", allocation_id: allocation.id, amount: "2000" },
      as: :json, headers: headers
    assert_response :created
    assert_equal first_id, response.parsed_body.dig("data", "id")
    get "#{base}/#{installment_id}", headers: api_headers(@read)
    assert_response :ok
    assert_equal "2500.0", response.parsed_body.dig("data", "outstanding_amount")
    get payment_path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ first_id ], response.parsed_body.fetch("data").pluck("id")
    assert_equal BigDecimal("2000"), entry.reload.amount
  end

  test "revoked account sharing hides fee settlement detail and aggregate paid amounts" do
    @account.update!(owner: users(:family_member))
    share = @account.account_shares.create!(user: @user, permission: "full_control")
    plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: @fields, key: "private-fee")
    due = Abroa::FeeInstallment.schedule_for!(@user, plan.id, attributes: {
      name: "Private term", gross_amount: "5000", discount_amount: "500", due_on: "2025-09-01" })
    entry = @account.entries.create!(entryable: Transaction.new, name: "Private payment",
      amount: 1000, currency: "GBP", date: Date.new(2025, 8, 1))
    allocation = Abroa::EntryAllocation.allocate_for!(@user, @project.id,
      entry_id: entry.id, amount: "1000", key: "private-pay")
    Abroa::FeeSettlement.pay_for!(@user, due.id, allocation_id: allocation.id,
      amount: "1000", key: "private-link")
    share.destroy!

    get "#{@path}/#{plan.id}", headers: api_headers(@read)
    assert_response :ok
    assert_nil response.parsed_body.dig("data", "paid_amount")
    assert_nil response.parsed_body.dig("data", "outstanding_amount")
    assert_equal true, response.parsed_body.dig("data", "incomplete")
    get "#{@path}/#{plan.id}/installments/#{due.id}", headers: api_headers(@read)
    assert_response :ok
    assert_nil response.parsed_body.dig("data", "paid_amount")
    get "#{@path}/#{plan.id}/installments/#{due.id}/settlements", headers: api_headers(@read)
    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
    budget = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: {
      name: "Private year", currency: "GBP", start_on: "2025-01-01",
      end_on: "2025-12-31", limit_amount: "10000" })
    projection = budget.execution_for!(@user)
    assert_equal true, projection[:incomplete]
    assert_nil projection[:committed]
    assert_includes projection[:issues].map { |issue| issue[:reason] }, "fee_source_not_visible"
  end

  test "Sure recurring occurrence imports are idempotent, permission scoped and ledger-free" do
    series = recurring_transactions(:netflix_subscription)
    plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "Recurring housing", kind: "rent", currency: "USD",
      gross_amount: "4000", discount_amount: "0", recurring_transaction_id: series.id
    }, key: "housing-series")
    occurrence = RecurringOccurrence.create!(family: @user.family, recurring_transaction: series,
      original_due_on: Date.new(2025, 9, 1), due_on: Date.new(2025, 9, 1),
      currency: "USD", expected_amount: 1000, status: "scheduled")
    path = "#{@path}/#{plan.id}/import_recurring"
    query = { from_on: "2025-09-01", through_on: "2025-10-01" }
    post path, params: query, as: :json, headers: api_headers(@read)
    assert_response :forbidden
    assert_no_difference "Entry.count" do
      post path, params: query, as: :json, headers: api_headers(@write)
      assert_response :ok
      assert_equal [ occurrence.id ], response.parsed_body.fetch("data").pluck("recurring_occurrence_id")
      assert_equal "1000.0", response.parsed_body.dig("data", 0, "gross_amount")
    end
    assert_no_difference "Abroa::FeeInstallment.count" do
      post path, params: query, as: :json, headers: api_headers(@write)
      assert_response :ok
    end
    post path, params: query, as: :json, headers: api_headers(@foreign)
    assert_response :not_found
  end

  test "stale writes and cancelled fees cannot be charged" do
    plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: @fields, key: "fee-cancel")
    post "#{@path}/#{plan.id}/cancel", params: { lock_version: plan.lock_version },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")
    post "#{@path}/#{plan.id}/installments",
      params: { name: "No longer due", due_on: "2025-09-01", gross_amount: "5000" },
      as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "cancelled-installment")
    assert_response :conflict
    patch "#{@path}/#{plan.id}", params: { lock_version: 0, name: "Stale update" },
      as: :json, headers: api_headers(@write)
    assert_response :conflict
  end
end
