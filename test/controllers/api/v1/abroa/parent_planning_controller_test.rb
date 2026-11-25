require "test_helper"

class Api::V1::Abroa::ParentPlanningControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @student_key = ApiKey.create!(user: @student, name: "Student",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_key = ApiKey.create!(user: @parent, name: "Parent",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_read = ApiKey.create!(user: @parent, name: "Read parent",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @outsider_key = ApiKey.create!(user: @outsider, name: "Outside",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    _invite, token = Abroa::RelationshipInvite.issue_for!(@student,
      recipient_email: @parent.email, recipient_role: "parent", key: "proposals-controller")
    @relation = Abroa::RelationshipInvite.accept_for!(@parent, token: token)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "London", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "parent-apis-project")
    @budget = Abroa::BudgetNode.create_for!(@student, @project.id,
      attributes: { name: "Living", start_on: "2025-01-01", end_on: "2025-12-31",
        currency: "GBP", limit_amount: "1000" }, key: "parent-apis-budget")
  end

  test "drafts are independent with API-key scopes and IDOR denial" do
    fields = { title: "Home budget", kind: "budget",
      payload: { name: "Living", start_on: "2025-01-01", end_on: "2025-12-31",
        currency: "GBP", limit_amount: "2000" } }
    post "/api/v1/abroa/parent/drafts", params: fields, as: :json
    assert_response :unauthorized
    post "/api/v1/abroa/parent/drafts", params: fields, as: :json,
      headers: api_headers(@parent_read).merge("Idempotency-Key" => "draft-1")
    assert_response :forbidden
    post "/api/v1/abroa/parent/drafts", params: fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "draft-1")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    assert_equal "draft", response.parsed_body.dig("data", "status")
    get "/api/v1/abroa/parent/drafts/#{id}", headers: api_headers(@student_key)
    assert_response :not_found
    get "/api/v1/abroa/parent/drafts", headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").pluck("id")
    patch "/api/v1/abroa/parent/drafts/#{id}",
      params: { title: "Updated", lock_version: 0 }, as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "Updated", response.parsed_body.dig("data", "title")
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
  end

  test "proposals require authorized grant and confirmation updates budget exactly once" do
    fields = { relationship_id: @relation.id, project_id: @project.id,
      target_id: @budget.id, operation: "budget_update", expected_version: @budget.lock_version,
      payload: { limit_amount: "1200" } }
    path = "/api/v1/abroa/proposals"
    post path, params: fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "not-granted")
    assert_response :not_found
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "propose", key: "allow")
    post path, params: fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "granted")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    version = response.parsed_body.dig("data", "lock_version")
    get "#{path}/#{id}", headers: api_headers(@outsider_key)
    assert_response :not_found
    post "#{path}/#{id}/submit", params: { lock_version: version }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :ok
    version = response.parsed_body.dig("data", "lock_version")
    post "#{path}/#{id}/accept", params: { lock_version: version }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :not_found
    post "#{path}/#{id}/accept", params: { lock_version: version }, as: :json,
      headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "accepted", response.parsed_body.dig("data", "status")
    assert_equal BigDecimal("1200"), @budget.reload.limit_amount
    version_count = @budget.versions.count
    post "#{path}/#{id}/accept", params: { lock_version: version }, as: :json,
      headers: api_headers(@student_key)
    assert_response :ok
    assert_equal version_count, @budget.versions.count
  end

  test "linked planning draft becomes effective only after student API approval" do
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "propose", key: "linked-draft-approval")
    draft_payload = { name: "Learning materials", limit_amount: "100",
      currency: "GBP", category_id: categories(:food_and_drink).id,
      start_on: "2025-01-01", end_on: "2025-12-31" }
    post "/api/v1/abroa/parent/drafts",
      params: { title: "Materials", kind: "budget", payload: draft_payload },
      as: :json, headers: api_headers(@parent_key).merge("Idempotency-Key" => "linked-draft")
    assert_response :created
    draft_id = response.parsed_body.dig("data", "id")
    post "/api/v1/abroa/proposals",
      params: { relationship_id: @relation.id, project_id: @project.id,
        operation: "budget_create", target_id: @project.id,
        payload: draft_payload, planning_draft_id: draft_id,
        expected_version: @project.lock_version }, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "linked-proposal")
    assert_response :created
    proposal_id = response.parsed_body.dig("data", "id")
    get "/api/v1/abroa/parent/drafts/#{draft_id}", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "submitted", response.parsed_body.dig("data", "status")
    proposal = Abroa::Proposal.find(proposal_id)
    post "/api/v1/abroa/proposals/#{proposal_id}/submit",
      params: { lock_version: proposal.lock_version }, as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    post "/api/v1/abroa/proposals/#{proposal_id}/accept",
      params: { lock_version: response.parsed_body.dig("data", "lock_version") },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "accepted", response.parsed_body.dig("data", "status")
    assert_equal "accepted", Abroa::PlanningDraft.find(draft_id).status
    assert_equal "Learning materials", Abroa::BudgetNode.find(response.parsed_body.dig("data", "applied_resource_id")).name
    get "/api/v1/abroa/parent/drafts/#{draft_id}", headers: api_headers(@student_key)
    assert_response :not_found
  end

  test "parent draft delete and stale version conflict preserve student data" do
    path = "/api/v1/abroa/parent/drafts"
    post path, params: { title: "Independent plan", kind: "budget",
      payload: { name: "Rent", currency: "GBP", limit_amount: "400",
        start_on: "2025-01-01", end_on: "2025-12-31" } }, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "cancel-draft")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    delete "#{path}/#{id}", params: { lock_version: 7 }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :conflict
    delete "#{path}/#{id}", params: { lock_version: 0 }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")
    delete "#{path}/#{id}", params: { lock_version: 1 }, as: :json,
      headers: api_headers(@parent_key)
    assert_response :conflict
    get "#{path}/#{id}", headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
  end

  test "proposal cancellation and student rejection are separately authorized" do
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "propose", key: "propose-cancel-reject")
    fields = { relationship_id: @relation.id, project_id: @project.id,
      target_id: @budget.id, operation: "budget_update",
      expected_version: @budget.lock_version, payload: { limit_amount: "800" } }
    path = "/api/v1/abroa/proposals"
    post path, params: fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "cancel-proposal")
    assert_response :created
    cancelled_id = response.parsed_body.dig("data", "id")
    post "#{path}/#{cancelled_id}/cancel", params: { lock_version: 0 },
      as: :json, headers: api_headers(@student_key)
    assert_response :not_found
    post "#{path}/#{cancelled_id}/cancel", params: { lock_version: 0 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "cancelled", response.parsed_body.dig("data", "status")

    post path, params: fields, as: :json,
      headers: api_headers(@parent_key).merge("Idempotency-Key" => "reject-proposal")
    assert_response :created
    rejected_id = response.parsed_body.dig("data", "id")
    post "#{path}/#{rejected_id}/submit", params: { lock_version: 0 },
      as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    version = response.parsed_body.dig("data", "lock_version")
    post "#{path}/#{rejected_id}/reject", params: { lock_version: version },
      as: :json, headers: api_headers(@parent_key)
    assert_response :not_found
    post "#{path}/#{rejected_id}/reject", params: { lock_version: version },
      as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "rejected", response.parsed_body.dig("data", "status")
    get "#{path}?status=rejected", headers: api_headers(@student_key)
    assert_response :ok
    assert_equal [ rejected_id ], response.parsed_body.fetch("data").pluck("id")
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
  end

  test "parent direct edit obeys explicit budget resource and immediate revoke" do
    grant = Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "budget_manage", resource_kind: "budget_node",
      resource_id: @budget.id, key: "manage")
    path = "/api/v1/abroa/parent/budgets/#{@budget.id}"
    patch path, params: { limit_amount: "1500", lock_version: @budget.lock_version },
      as: :json, headers: api_headers(@parent_read)
    assert_response :forbidden
    patch path, params: { limit_amount: "1500", lock_version: @budget.lock_version },
      as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal BigDecimal("1500"), @budget.reload.limit_amount
    Abroa::Grant.revoke_for!(@student, @relation.id, grant.id, version: grant.lock_version)
    patch path, params: { limit_amount: "1700", lock_version: @budget.lock_version },
      as: :json, headers: api_headers(@parent_key)
    assert_response :not_found
    assert_equal BigDecimal("1500"), @budget.reload.limit_amount
  end
end
