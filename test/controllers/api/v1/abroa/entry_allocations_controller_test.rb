require "test_helper"

class Api::V1::Abroa::EntryAllocationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @read = ApiKey.create!(user: @user, name: "entry-alloc-read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @write = ApiKey.create!(user: @user, name: "entry-alloc-write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Study allocation", country: "GB", timezone: "Europe/London", currency: "GBP",
      start_on: "2025-01-01", end_on: "2025-12-31" }, key: "alloc-controller")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Allocated cash", currency: "GBP", balance: 1000)
    @entry = @account.entries.create!(entryable: Transaction.new, name: "Transaction", amount: 100,
      currency: "GBP", date: Date.new(2025, 3, 1))
    @path = "/api/v1/abroa/projects/#{@project.id}/allocations"
  end

  test "allocation is private, scoped, versioned and never mutates the original entry" do
    post @path, params: { entry_id: @entry.id, amount: "60" }, as: :json,
      headers: api_headers(@read).merge("Idempotency-Key" => "first")
    assert_response :forbidden
    post @path, params: { entry_id: @entry.id, amount: "60" }, as: :json,
      headers: api_headers(@write).merge("Idempotency-Key" => "first")
    assert_response :created
    allocation = response.parsed_body.fetch("data")
    assert_equal "60.0", allocation.fetch("amount")
    patch "#{@path}/#{allocation.fetch('id')}", params: { lock_version: allocation.fetch("lock_version"), category_id: categories(:food_and_drink).id },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal categories(:food_and_drink).id, response.parsed_body.dig("data", "category_id")
    assert_equal BigDecimal("100"), @entry.reload.amount
    patch "#{@path}/#{allocation.fetch('id')}", params: { lock_version: allocation.fetch("lock_version"), amount: "90" },
      as: :json, headers: api_headers(@write)
    assert_response :conflict
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ allocation.fetch("id") ], response.parsed_body.fetch("data").pluck("id")
    delete "#{@path}/#{allocation.fetch('id')}", params: { lock_version: response.parsed_body.fetch("data").first.fetch("lock_version") },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal 0, @project.allocations.count
    assert_equal BigDecimal("100"), @entry.reload.amount
  end
end
