require "test_helper"

class Api::V1::Abroa::ProjectsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @foreign = users(:empty)
    @write = ApiKey.create!(user: @user, name: "Projects write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read = ApiKey.create!(user: @user, name: "Projects read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @foreign_key = ApiKey.create!(user: @foreign, name: "Other read", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @fields = { name: "London", country: "GB", origin_country: "CN", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31" }
  end

  test "project create requires write scope and replays idempotency key" do
    post "/api/v1/abroa/projects", params: @fields, as: :json, headers: api_headers(@read).merge("Idempotency-Key" => "create-1")
    assert_response :forbidden
    post "/api/v1/abroa/projects", params: @fields, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity
    headers = api_headers(@write).merge("Idempotency-Key" => "create-1")
    assert_difference "Abroa::StudyProject.count", 1 do
      post "/api/v1/abroa/projects", params: @fields, as: :json, headers: headers
      assert_response :created
    end
    id = response.parsed_body.dig("data", "id")
    post "/api/v1/abroa/projects", params: @fields, as: :json, headers: headers
    assert_response :created
    assert_equal id, response.parsed_body.dig("data", "id")
    post "/api/v1/abroa/projects", params: @fields.merge(name: "Paris"), as: :json, headers: headers
    assert_response :conflict
  end

  test "project scoped listing, change and archive restoration" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @fields, key: "created")
    get "/api/v1/abroa/projects", headers: api_headers(@read)
    assert_response :ok
    assert_includes response.parsed_body.fetch("data").pluck("id"), project.id
    get "/api/v1/abroa/projects/#{project.id}", headers: api_headers(@foreign_key)
    assert_response :not_found
    get "/api/v1/abroa/projects/#{project.id}"
    assert_response :unauthorized
    patch "/api/v1/abroa/projects/#{project.id}", params: { name: "Oxford", lock_version: project.lock_version },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    version = response.parsed_body.dig("data", "lock_version")
    post "/api/v1/abroa/projects/#{project.id}/archive", params: { lock_version: version }, as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "archived", response.parsed_body.dig("data", "status")
    post "/api/v1/abroa/projects/#{project.id}/restore", params: { lock_version: response.parsed_body.dig("data", "lock_version") },
      as: :json, headers: api_headers(@write)
    assert_response :ok
    assert_equal "planning", response.parsed_body.dig("data", "status")
  end

  test "project list pagination is stable and rejects malformed cursors" do
    3.times do |i|
      Abroa::StudyProject.create_for!(@user, attributes: @fields.merge(name: "Program #{i}"), key: "page-#{i}")
    end
    get "/api/v1/abroa/projects", params: { limit: 2 }, headers: api_headers(@read)
    assert_response :ok
    ids = response.parsed_body.fetch("data").pluck("id")
    assert_equal 2, ids.size
    cursor = response.parsed_body.dig("meta", "next_cursor")
    assert cursor.present?
    get "/api/v1/abroa/projects", params: { limit: 2, cursor: cursor }, headers: api_headers(@read)
    assert_response :ok
    more = response.parsed_body.fetch("data").pluck("id")
    assert_equal 1, more.size
    assert_equal 3, (ids + more).uniq.size
    get "/api/v1/abroa/projects", params: { limit: 0 }, headers: api_headers(@read)
    assert_response :unprocessable_entity
    get "/api/v1/abroa/projects", params: { cursor: "not-a-cursor" }, headers: api_headers(@read)
    assert_response :unprocessable_entity
  end

  test "allocation create replay is atomic and audited once" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @fields, key: "idempotent-project")
    account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Project allocation cash", currency: "GBP", balance: 1000)
    entry = account.entries.create!(entryable: Transaction.new, name: "Rent", amount: 100, currency: "GBP", date: Date.new(2025, 3, 1))
    path = "/api/v1/abroa/projects/#{project.id}/allocations"
    headers = api_headers(@write).merge("Idempotency-Key" => "rent-split-one")
    post path, params: { entry_id: entry.id, amount: "60" }, as: :json, headers: api_headers(@write)
    assert_response :unprocessable_entity

    assert_difference "Abroa::EntryAllocation.count", 1 do
      post path, params: { entry_id: entry.id, amount: "60" }, as: :json, headers: headers
      assert_response :created
    end
    first_id = response.parsed_body.dig("data", "id")
    assert_no_difference "Abroa::EntryAllocation.count" do
      post path, params: { entry_id: entry.id, amount: "60" }, as: :json, headers: headers
      assert_response :created
      assert_equal first_id, response.parsed_body.dig("data", "id")
    end
    post path, params: { entry_id: entry.id, amount: "70" }, as: :json, headers: headers
    assert_response :conflict
    assert_equal BigDecimal("60"), Abroa::EntryAllocation.where(entry_id: entry.id).sum(:amount)
    assert_equal 1, Abroa::PlanningAuditEvent.where(resource_id: first_id, event_type: "entry_allocation.created").count
    assert_equal BigDecimal("100"), entry.reload.amount
  end

  test "period creation replay and currency conversion gaps preserve historical data" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @fields, key: "period-project")
    path = "/api/v1/abroa/projects/#{project.id}/periods"
    headers = api_headers(@write).merge("Idempotency-Key" => "year-two")
    fields = { kind: "year", name: "Year two", start_on: "2025-01-01", end_on: "2025-12-31" }
    post path, params: fields, as: :json, headers: headers
    assert_response :created
    first_id = response.parsed_body.dig("data", "id")
    assert_no_difference "Abroa::StudyPeriod.count" do
      post path, params: fields, as: :json, headers: headers
      assert_response :created
      assert_equal first_id, response.parsed_body.dig("data", "id")
    end
    post path, params: fields.merge(name: "Changed"), as: :json, headers: headers
    assert_response :conflict
    assert_equal 1, Abroa::PlanningAuditEvent.where(resource_id: first_id, event_type: "study_period.created").count
  end

  test "periods, shared accounts, ledger allocations and summary do not mutate transactions" do
    project = Abroa::StudyProject.create_for!(@user, attributes: @fields, key: "created")
    other = Abroa::StudyProject.create_for!(@user, attributes: @fields.merge(name: "Oxford"), key: "created2")
    account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Student cash", currency: "GBP", balance: 1000)
    entry = account.entries.create!(entryable: Transaction.new, name: "Purchase", amount: 100,
      currency: "GBP", date: Date.new(2025, 3, 1))
    [ project, other ].each do |p|
      post "/api/v1/abroa/projects/#{p.id}/accounts", params: { account_id: account.id },
        as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "link-#{p.id}")
      assert_response :created
    end
    post "/api/v1/abroa/projects/#{project.id}/periods",
      params: { name: "Year 1", kind: "year", start_on: "2025-01-01", end_on: "2025-12-31" },
      as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "year-1")
    assert_response :created
    post "/api/v1/abroa/projects/#{project.id}/allocations",
      params: { entry_id: entry.id, amount: "60" }, as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "alloc-a")
    assert_response :created
    post "/api/v1/abroa/projects/#{other.id}/allocations",
      params: { entry_id: entry.id, amount: "30" }, as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "alloc-b")
    assert_response :created
    post "/api/v1/abroa/projects/#{other.id}/allocations",
      params: { entry_id: entry.id, amount: "20" }, as: :json, headers: api_headers(@write).merge("Idempotency-Key" => "alloc-over")
    assert_response :unprocessable_entity
    get "/api/v1/abroa/projects/#{project.id}/summary", params: { start_on: "2025-01-01", end_on: "2025-12-31", currency: "GBP" },
      headers: api_headers(@read)
    assert_response :ok
    assert_equal "60.0", response.parsed_body.dig("data", "net_consumption")
    assert_equal BigDecimal("100"), entry.reload.amount
  end
end
