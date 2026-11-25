require "test_helper"

class Api::V1::Abroa::RelationshipsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @other = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @student_key = ApiKey.create!(user: @student, name: "Student write",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_key = ApiKey.create!(user: @parent, name: "Parent write",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_read = ApiKey.create!(user: @parent, name: "Parent read",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @other_key = ApiKey.create!(user: @other, name: "Not a parent",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "London", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "relationships-api-project")
  end

  test "authorization, invitation replay, one-time acceptance and visibility" do
    path = "/api/v1/abroa/relationship_invites"
    params = { recipient_email: @student.email, recipient_role: "student" }
    post path, params: params, as: :json
    assert_response :unauthorized
    post path, params: params, as: :json,
      headers: api_headers(@parent_read).merge("Idempotency-Key" => "invite-1")
    assert_response :forbidden
    headers = api_headers(@parent_key).merge("Idempotency-Key" => "invite-1")
    post path, params: params, as: :json, headers: headers
    assert_response :created
    token = response.parsed_body.dig("data", "invitation_token")
    assert_equal 64, token.length
    invitation_id = response.parsed_body.dig("data", "id")
    post path, params: params, as: :json, headers: headers
    assert_response :created
    assert_equal token, response.parsed_body.dig("data", "invitation_token")
    post "#{path}/accept", params: { token: token }, as: :json, headers: api_headers(@other_key)
    assert_response :not_found
    post "#{path}/accept", params: { token: token }, as: :json, headers: api_headers(@student_key)
    assert_response :ok
    relation_id = response.parsed_body.dig("data", "id")
    post "#{path}/accept", params: { token: token }, as: :json, headers: api_headers(@student_key)
    assert_response :conflict
    get "/api/v1/abroa/relationships/#{relation_id}", headers: api_headers(@other_key)
    assert_response :not_found
    get "#{path}/#{invitation_id}", headers: api_headers(@other_key)
    assert_response :not_found
    get "/api/v1/abroa/relationships", headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal [ relation_id ], response.parsed_body.fetch("data").pluck("id")
    assert_not response.parsed_body.to_json.include?("token_digest")
  end

  test "invitation rejection and inviter revocation are explicit and cannot be replayed" do
    path = "/api/v1/abroa/relationship_invites"
    headers = api_headers(@parent_key).merge("Idempotency-Key" => "reject-invite")
    post path, params: { recipient_email: @student.email, recipient_role: "student" },
      as: :json, headers: headers
    assert_response :created
    token = response.parsed_body.dig("data", "invitation_token")
    invitation_id = response.parsed_body.dig("data", "id")
    post "#{path}/reject", params: { token: token }, as: :json,
      headers: api_headers(@other_key)
    assert_response :not_found
    post "#{path}/reject", params: { token: token }, as: :json,
      headers: api_headers(@student_key)
    assert_response :ok
    assert_equal "rejected", response.parsed_body.dig("data", "status")
    post "#{path}/accept", params: { token: token }, as: :json,
      headers: api_headers(@student_key)
    assert_response :conflict
    get "#{path}/#{invitation_id}", headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "rejected", response.parsed_body.dig("data", "status")

    headers = api_headers(@parent_key).merge("Idempotency-Key" => "revoke-invite")
    post path, params: { recipient_email: @student.email, recipient_role: "student" },
      as: :json, headers: headers
    assert_response :created
    new_token = response.parsed_body.dig("data", "invitation_token")
    new_id = response.parsed_body.dig("data", "id")
    delete "#{path}/#{new_id}", as: :json, headers: api_headers(@student_key)
    assert_response :not_found
    delete "#{path}/#{new_id}", as: :json, headers: api_headers(@parent_key)
    assert_response :ok
    assert_equal "revoked", response.parsed_body.dig("data", "status")
    post "#{path}/accept", params: { token: new_token }, as: :json,
      headers: api_headers(@student_key)
    assert_response :conflict
    assert_equal 0, Abroa::Relationship.count
  end

  test "only student grants scoped capability and revocation takes effect immediately" do
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "grant-invite")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    path = "/api/v1/abroa/relationships/#{relation.id}/grants"
    fields = { project_id: @project.id, capability: "summary" }
    headers = api_headers(@student_key).merge("Idempotency-Key" => "summary-grant")
    post path, params: fields, as: :json, headers: api_headers(@parent_key).merge("Idempotency-Key" => "illegal")
    assert_response :not_found
    post path, params: fields, as: :json, headers: headers
    assert_response :created
    grant_id = response.parsed_body.dig("data", "id")
    version = response.parsed_body.dig("data", "lock_version")
    assert Abroa::Grant.allowed?(@parent, @project, "summary")
    get path, headers: api_headers(@parent_read)
    assert_response :ok
    assert_equal [ grant_id ], response.parsed_body.fetch("data").pluck("id")
    post path, params: fields.merge(capability: "budget_manage"), as: :json, headers: headers
    assert_response :conflict
    delete "#{path}/#{grant_id}", params: { lock_version: version }, as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_not Abroa::Grant.allowed?(@parent, @project, "summary")
    get path, headers: api_headers(@parent_read)
    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
  end

  test "relationship revocation locks grants and blocks parent reads" do
    _invite, token = Abroa::RelationshipInvite.issue_for!(@student,
      recipient_email: @parent.email, recipient_role: "parent", key: "revoke-invite")
    relation = Abroa::RelationshipInvite.accept_for!(@parent, token: token)
    Abroa::Grant.create_for!(@student, relation.id, project_id: @project.id,
      capability: "summary", key: "first-grant")
    post "/api/v1/abroa/relationships/#{relation.id}/revoke",
      params: { lock_version: relation.lock_version }, as: :json, headers: api_headers(@student_key)
    assert_response :ok
    assert_not Abroa::Grant.allowed?(@parent, @project, "summary")
    get "/api/v1/abroa/relationships/#{relation.id}/grants", headers: api_headers(@parent_read)
    assert_response :not_found
  end
end
