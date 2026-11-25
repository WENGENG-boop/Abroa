require "test_helper"

class Api::V1::Abroa::FundingPlansControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @student_key = ApiKey.create!(user: @student, name: "Student funding",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_key = ApiKey.create!(user: @parent, name: "Parent funding",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_read = ApiKey.create!(user: @parent, name: "Parent read funding",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @outsider_key = ApiKey.create!(user: @outsider, name: "Outsider funding",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    _invite, token = Abroa::RelationshipInvite.issue_for!(@student,
      recipient_email: @parent.email, recipient_role: "parent", key: "funding-controllers")
    @relation = Abroa::RelationshipInvite.accept_for!(@parent, token: token)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "UK", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2026-12-31"
    }, key: "funding-api-project")
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Student bank", currency: "GBP", balance: 1000)
    @source = Account.create!(family: @parent.family, owner: @parent,
      accountable: Depository.new, name: "Parent bank", currency: "GBP", balance: 2000)
    @fields = { relationship_id: @relation.id, project_id: @project.id,
      name: "Living support", amount: "1000", currency: "GBP", frequency: "once",
      scheduled_on: "2025-02-10", source_account_id: @source.id }
  end

  test "create, confirm and partial receipt enforce scopes and private source account" do
    path = "/api/v1/abroa/funding_plans"
    post path, params: @fields, as: :json
    assert_response :unauthorized
    post path, params: @fields, as: :json,
      headers: api_headers(@parent_read).merge("Idempotency-Key" => "create")
    assert_response :forbidden
    post path, params: @fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "create")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    assert_equal @source.id, response.parsed_body.dig("data", "source_account_id")
    get "#{path}/#{id}", headers: api_headers(@outsider_key)
    assert_response :not_found
    get "#{path}/#{id}", headers: api_headers(@student_key)
    assert_response :ok
    assert_not response.parsed_body.to_json.include?(@source.id)
    post "#{path}/#{id}/confirm", params: { lock_version: 0, destination_account_id: @account.id },
      as: :json, headers: api_headers(@parent_key)
    assert_response :not_found
    post "#{path}/#{id}/confirm", params: { lock_version: 0, destination_account_id: @account.id },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    entry = @account.entries.create!(entryable: Transaction.new, name: "Family cash",
      amount: -400, currency: "GBP", date: Date.new(2025, 2, 10))
    baseline_balance = @account.reload.balance
    baseline_entries = Entry.count
    post "#{path}/#{id}/receipts", params: { entry_id: entry.id },
      as: :json, headers: api_headers(@parent_key).merge("Idempotency-Key" => "wrong")
    assert_response :not_found
    post "#{path}/#{id}/receipts", params: { entry_id: entry.id },
      as: :json, headers: api_headers(@student_key).merge("Idempotency-Key" => "first")
    assert_response :created
    assert_equal "400.0", response.parsed_body.dig("data", "applied_amount")
    get "#{path}/#{id}", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "400.0", response.parsed_body.dig("data", "received_amount")
    assert_not response.parsed_body.to_json.include?(entry.id)
    assert_not response.parsed_body.to_json.include?(@account.id)
    assert_equal baseline_balance, @account.reload.balance
    assert_equal baseline_entries, Entry.count
  end

  test "parent sends a notice but matching requires a real posted bank transaction" do
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: @fields.except(:relationship_id, :project_id), key: "notice-plan")
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: @account.id)
    count = Entry.count
    post "/api/v1/abroa/funding_plans/#{plan.id}/notices",
      params: { amount: "600", reported_on: "2025-02-10" }, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "sent")
    assert_response :created
    get "/api/v1/abroa/funding_plans/#{plan.id}", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "0.0", response.parsed_body.dig("data", "received_amount")
    assert_equal "600.0", response.parsed_body.dig("data", "pending_matching_amount")
    assert_equal count, Entry.count
    get "/api/v1/abroa/funding_plans/#{plan.id}/notices", headers: api_headers(@outsider_key)
    assert_response :not_found
  end

  test "student funding suggestion requires parent approval and hides after link revoke" do
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: @fields.except(:relationship_id, :project_id), key: "suggestion-plan")
    path = "/api/v1/abroa/funding_plans/#{plan.id}/suggestions"
    post path, params: { amount: "750" }, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "parent-cannot-suggest")
    assert_response :not_found
    post path, params: { amount: "750" }, as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "student-suggest")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    version = response.parsed_body.dig("data", "lock_version")
    assert_equal BigDecimal("1000"), plan.reload.amount
    get path, headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
    post "#{path}/#{id}/accept", params: { lock_version: version }, as: :json,
      headers: api_headers(@student_key)
    assert_response :not_found
    post "#{path}/#{id}/accept", params: { lock_version: version }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal BigDecimal("750"), plan.reload.amount
    Abroa::Relationship.revoke_for!(@student, @relation.id, version: @relation.lock_version)
    get path, headers: api_headers(@parent_read)
    assert_response :not_found
  end

  test "funding update, reject, and cancel require role and exact version" do
    path = "/api/v1/abroa/funding_plans"
    post path, params: @fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "update-reject")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    patch "#{path}/#{id}", params: { amount: "800", lock_version: 0 },
      as: :json, headers: api_headers(@student_key)
    assert_response :not_found
    patch "#{path}/#{id}", params: { amount: "800", lock_version: 0 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "800.0", response.parsed_body.dig("data", "amount")
    version = response.parsed_body.dig("data", "lock_version")
    patch "#{path}/#{id}", params: { amount: "700", lock_version: 0 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :conflict
    post "#{path}/#{id}/reject", params: { lock_version: version },
      as: :json, headers: api_headers(@parent_key)
    assert_response :not_found
    post "#{path}/#{id}/reject", params: { lock_version: version },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "rejected", response.parsed_body.dig("data", "status")
    post "#{path}/#{id}/cancel", params: { lock_version: version + 1 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :conflict

    post path, params: @fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "cancel-confirmed")
    assert_response :created
    confirmed_id = response.parsed_body.dig("data", "id")
    post "#{path}/#{confirmed_id}/confirm",
      params: { destination_account_id: @account.id, lock_version: 0 },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    confirmed_version = response.parsed_body.dig("data", "lock_version")
    post "#{path}/#{confirmed_id}/cancel",
      params: { lock_version: confirmed_version }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")
    get "#{path}/#{confirmed_id}", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")
  end

  test "notice revocation and receipt/reversal lists respect grants and real ledger" do
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: @fields.except(:relationship_id, :project_id),
      key: "list-and-revoke")
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: @account.id)
    path = "/api/v1/abroa/funding_plans/#{plan.id}"
    post "#{path}/notices",
      params: { amount: "300", reported_on: "2025-02-10" }, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "report-sent")
    assert_response :created
    notice_id = response.parsed_body.dig("data", "id")
    get "#{path}/notices", headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal [ notice_id ], response.parsed_body.fetch("data").pluck("id")
    post "#{path}/notices/#{notice_id}/revoke",
      params: { lock_version: 0 }, as: :json, headers: api_headers(@student_key)
    assert_response :not_found
    post "#{path}/notices/#{notice_id}/revoke",
      params: { lock_version: 0 }, as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "revoked", response.parsed_body.dig("data", "status")
    assert_equal BigDecimal("0"), plan.reload.pending_match_total

    incoming = @account.entries.create!(entryable: Transaction.new,
      name: "Verified incoming cash", amount: -400, currency: "GBP", date: Date.new(2025, 2, 10))
    post "#{path}/receipts", params: { entry_id: incoming.id }, as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "listed-receipt")
    assert_response :created
    receipt_id = response.parsed_body.dig("data", "id")
    get "#{path}/receipts", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal [ receipt_id ], response.parsed_body.fetch("data").pluck("id")
    get "#{path}/receipts/#{receipt_id}", headers: api_headers(@parent_read)
    assert_response :not_found
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "transaction_details", key: "detailed-receipts")
    get "#{path}/receipts/#{receipt_id}", headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal receipt_id, response.parsed_body.dig("data", "id")
    assert_not response.parsed_body.to_json.include?(incoming.id)

    refund = @account.entries.create!(entryable: Transaction.new,
      name: "Verified outgoing refund", amount: 100, currency: "GBP", date: Date.new(2025, 2, 11))
    post "/api/v1/abroa/funding_receipts/#{receipt_id}/reversals",
      params: { entry_id: refund.id }, as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "listed-reversal")
    assert_response :created
    reversal_id = response.parsed_body.dig("data", "id")
    get "/api/v1/abroa/funding_receipts/#{receipt_id}/reversals",
      headers: api_headers(@student_key)
    assert_response :ok
    assert_equal [ reversal_id ], response.parsed_body.fetch("data").pluck("id")
    get "/api/v1/abroa/funding_receipts/#{receipt_id}/reversals",
      headers: api_headers(@parent_read)
    assert_response :not_found
    assert_equal BigDecimal("300"), plan.reload.received_total
  end

  test "student may cancel a suggestion and parent alone may reject it" do
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: @fields.except(:relationship_id, :project_id),
      key: "suggestion-cancel-reject")
    path = "/api/v1/abroa/funding_plans/#{plan.id}/suggestions"
    post path, params: { amount: "900" }, as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "suggest-reject")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    post "#{path}/#{id}/reject", params: { lock_version: 0 },
      as: :json, headers: api_headers(@student_key)
    assert_response :not_found
    post "#{path}/#{id}/reject", params: { lock_version: 0 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "rejected", response.parsed_body.dig("data", "status")
    post path, params: { amount: "850" }, as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "suggest-cancel")
    assert_response :created
    another_id = response.parsed_body.dig("data", "id")
    post "#{path}/#{another_id}/cancel", params: { lock_version: 0 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :not_found
    post "#{path}/#{another_id}/cancel", params: { lock_version: 0 },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")
    assert_equal BigDecimal("1000"), plan.reload.amount
  end

  test "real refund reversal preserves original entry and adjusts planned reporting" do
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: @fields.except(:relationship_id, :project_id), key: "refund-plan")
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id, version: plan.lock_version,
      destination_account_id: @account.id)
    inflow = @account.entries.create!(entryable: Transaction.new, name: "Incoming transfer",
      amount: -500, currency: "GBP", date: Date.new(2025, 2, 10))
    receipt = Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: inflow.id, key: "match")
    refund = @account.entries.create!(entryable: Transaction.new, name: "Returned transfer",
      amount: 200, currency: "GBP", date: Date.new(2025, 2, 11))
    count = Entry.count
    post "/api/v1/abroa/funding_receipts/#{receipt.id}/reversals",
      params: { entry_id: refund.id }, as: :json, headers: api_headers(@student_key).merge("Idempotency-Key" => "refund")
    assert_response :created
    get "/api/v1/abroa/funding_plans/#{plan.id}", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "300.0", response.parsed_body.dig("data", "received_amount")
    assert_equal count, Entry.count
    assert_equal BigDecimal("500"), inflow.reload.amount.abs
  end
end
