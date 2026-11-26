require "test_helper"

class AbroaP6CrossModuleAcceptanceTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @student_key = ApiKey.create!(user: @student, name: "P6 student", key: ApiKey.generate_secure_key,
      scopes: %w[read_write], source: "web")
    @parent_key = ApiKey.create!(user: @parent, name: "P6 parent", key: ApiKey.generate_secure_key,
      scopes: %w[read_write], source: "web")
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Private P6 tuition cash", currency: "GBP", balance: 1000)
    @entry = @account.entries.create!(entryable: Transaction.new,
      name: "Private P6 merchant", amount: BigDecimal("100.0000"), currency: "GBP", date: Date.new(2025, 3, 1))
  end

  test "API study split, fee settlement, pool allocation and parent revocation preserve native ledger" do
    before_entry_count = Entry.count
    before_balance = @account.reload.balance
    london = create_project("London", "p6-project-a")
    oxford = create_project("Oxford", "p6-project-b")
    [ london, oxford ].each do |project_id|
      post "/api/v1/abroa/projects/#{project_id}/accounts",
        params: { account_id: @account.id }, as: :json, headers: student_headers("p6-link-#{project_id}")
      assert_response :created
    end

    first = allocation(london, "60", "p6-allocation-a")
    allocation(oxford, "30", "p6-allocation-b")
    assert_no_difference -> { Abroa::EntryAllocation.count } do
      post "/api/v1/abroa/projects/#{oxford}/allocations",
        params: { entry_id: @entry.id, amount: "20" }, as: :json,
        headers: student_headers("p6-allocation-over-limit")
      assert_response :unprocessable_entity
    end
    assert_equal BigDecimal("90"), Abroa::EntryAllocation.where(entry_id: @entry.id).sum(:amount)
    assert_equal BigDecimal("100"), @entry.reload.amount
    assert_equal before_entry_count, Entry.count

    post "/api/v1/abroa/projects/#{london}/pools",
      params: { name: "Tuition reserve", kind: "tuition", currency: "GBP", target_amount: "500" },
      as: :json, headers: student_headers("p6-pool")
    assert_response :created
    pool_id = response.parsed_body.dig("data", "id")
    post "/api/v1/abroa/projects/#{london}/pools/#{pool_id}/movements",
      params: { account_id: @account.id, kind: "allocate", amount: "200" },
      as: :json, headers: student_headers("p6-pool-allocate")
    assert_response :created
    assert_equal before_balance, @account.reload.balance
    assert_equal before_entry_count, Entry.count

    post "/api/v1/abroa/projects/#{london}/fees",
      params: { name: "Term tuition", kind: "tuition", currency: "GBP",
        gross_amount: "120", discount_amount: "0" },
      as: :json, headers: student_headers("p6-fee")
    assert_response :created
    fee_id = response.parsed_body.dig("data", "id")
    base = "/api/v1/abroa/projects/#{london}/fees/#{fee_id}/installments"
    post base, params: { name: "Spring", gross_amount: "120",
      discount_amount: "0", due_on: "2025-06-01" },
      as: :json, headers: student_headers("p6-installment")
    assert_response :created
    installment_id = response.parsed_body.dig("data", "id")
    payment_path = "#{base}/#{installment_id}/settlements"
    assert_no_difference -> { Entry.count } do
      post payment_path, params: { kind: "payment", allocation_id: first, amount: "50" },
        as: :json, headers: student_headers("p6-settlement")
      assert_response :created
    end
    settlement_id = response.parsed_body.dig("data", "id")
    post payment_path, params: { kind: "payment", allocation_id: first, amount: "50" },
      as: :json, headers: student_headers("p6-settlement")
    assert_response :created
    assert_equal settlement_id, response.parsed_body.dig("data", "id")
    get "#{base}/#{installment_id}", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal BigDecimal("70"), BigDecimal(response.parsed_body.dig("data", "outstanding_amount"))

    get "/api/v1/abroa/projects/#{london}/summary",
      params: { start_on: "2025-01-01", end_on: "2025-12-31", currency: "GBP" },
      headers: api_headers(@student_key)
    assert_response :ok
    assert_equal BigDecimal("60"), BigDecimal(response.parsed_body.dig("data", "net_consumption"))

    _invitation, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "p6-parent-invitation")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id, project_id: london,
      capability: "summary", key: "p6-summary-grant")
    path = "/api/v1/abroa/parent/projects/#{london}/summary"
    get path, headers: api_headers(@parent_key)
    assert_response :ok
    assert_not_includes response.body, @account.name
    assert_not_includes response.body, @account.id
    get "/api/v1/abroa/parent/projects/#{oxford}/summary", headers: api_headers(@parent_key)
    assert_response :not_found
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    get path, headers: api_headers(@parent_key)
    assert_response :not_found
    get "/api/v1/transactions", headers: api_headers(@parent_key)
    assert_response :ok
    assert_not_includes response.body, @entry.id

    assert_equal before_balance, @account.reload.balance
    assert_equal BigDecimal("100"), @entry.reload.amount
    assert_equal before_entry_count, Entry.count
  end

  private
    def create_project(name, key)
      post "/api/v1/abroa/projects",
        params: { name: name, country: "GB", origin_country: "CN", currency: "GBP",
          timezone: "Europe/London", start_on: "2025-01-01", end_on: "2025-12-31" },
        as: :json, headers: student_headers(key)
      assert_response :created
      response.parsed_body.dig("data", "id")
    end

    def allocation(project_id, amount, key)
      post "/api/v1/abroa/projects/#{project_id}/allocations",
        params: { entry_id: @entry.id, amount: amount }, as: :json, headers: student_headers(key)
      assert_response :created
      response.parsed_body.dig("data", "id")
    end

    def student_headers(key)
      api_headers(@student_key).merge("Idempotency-Key" => key)
    end
end
