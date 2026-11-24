require "test_helper"

class Api::V1::Abroa::FundPoolsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @foreign = users(:empty)
    @write = ApiKey.create!(user: @user, name: "fund-write", key: ApiKey.generate_secure_key,
      scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "fund-read", key: ApiKey.generate_secure_key,
      scopes: %w[read], source: "web")
    @foreign_key = ApiKey.create!(user: @foreign, name: "fund-other",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fund API", country: "GB", timezone: "Europe/London", currency: "GBP",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "fund-api")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Funds account", currency: "GBP", balance: 100_000)
    @path = "/api/v1/abroa/projects/#{@project.id}/pools"
    @fields = { name: "Tuition pool", kind: "tuition", currency: "GBP", target_amount: "60000" }
  end

  test "project fund pool creation is authorized and idempotent" do
    post @path, params: @fields, as: :json, headers: api_headers(@read).merge("Idempotency-Key" => "new")
    assert_response :forbidden
    post @path, params: @fields, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity
    headers = api_headers(@write).merge("Idempotency-Key" => "new")
    assert_difference "Abroa::FundPool.count", 1 do
      post @path, params: @fields, as: :json, headers: headers
      assert_response :created
    end
    id = response.parsed_body.dig("data", "id")
    assert_no_difference "Abroa::FundPool.count" do
      post @path, params: @fields, as: :json, headers: headers
      assert_response :created
      assert_equal id, response.parsed_body.dig("data", "id")
    end
    post @path, params: @fields.merge(target_amount: "80000"), as: :json, headers: headers
    assert_response :conflict
    get "#{@path}/#{id}", headers: api_headers(@foreign_key)
    assert_response :not_found
    get @path, headers: api_headers(@read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
  end

  test "virtual pool movements do not change actual balance and expose shortfall" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: @fields)
    base = "#{@path}/#{pool.id}/movements"
    post base, params: { account_id: @account.id, kind: "allocate", amount: "80000" }, as: :json,
      headers: api_headers(@read).merge("Idempotency-Key" => "allocate")
    assert_response :forbidden
    headers = api_headers(@write).merge("Idempotency-Key" => "allocate")
    assert_difference "Abroa::PoolMovement.count", 1 do
      post base, params: { account_id: @account.id, kind: "allocate", amount: "80000" }, as: :json, headers: headers
      assert_response :created
    end
    id = response.parsed_body.dig("data", "id")
    post base, params: { account_id: @account.id, kind: "allocate", amount: "80000" }, as: :json, headers: headers
    assert_response :created
    assert_equal id, response.parsed_body.dig("data", "id")
    get "#{@path}/cash/#{@account.id}", headers: api_headers(@read)
    assert_response :ok
    assert_equal "20000.0", response.parsed_body.dig("data", "unallocated_cash")
    assert_equal BigDecimal("100000"), @account.reload.balance
    @account.update!(balance: 70_000)
    get "#{@path}/cash/#{@account.id}", headers: api_headers(@read)
    assert_response :ok
    assert_equal "10000.0", response.parsed_body.dig("data", "shortfall")
    post base, params: { account_id: @account.id, kind: "allocate", amount: "1" }, as: :json,
      headers: api_headers(@write).merge("Idempotency-Key" => "overdraw")
    assert_response :unprocessable_entity
  end

  test "pool archive and restore retain reserved money and lock versions" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: @fields)
    Abroa::PoolMovement.apply_for!(@user, pool.id,
      account_id: @account.id, kind: "allocate", amount: "20000", key: "allocate")
    post "#{@path}/#{pool.id}/archive", params: { lock_version: pool.lock_version },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "archived", response.parsed_body.dig("data", "status")
    archived_version = response.parsed_body.dig("data", "lock_version")
    post "#{@path}/#{pool.id}/movements", params: {
      account_id: @account.id, kind: "allocate", amount: "1"
    }, as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "new-on-archive")
    assert_response :conflict
    post "#{@path}/#{pool.id}/restore", params: {
      lock_version: archived_version
    }, as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "active", response.parsed_body.dig("data", "status")
    assert_equal BigDecimal("20000"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("100000"), @account.reload.balance
  end
end
