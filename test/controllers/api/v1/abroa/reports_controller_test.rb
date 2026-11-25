require "test_helper"

class Api::V1::Abroa::ReportsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @other = users(:empty)
    @student_key = ApiKey.create!(user: @student, name: "P4 reports writer",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @student, name: "P4 reports readonly",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @other_key = ApiKey.create!(user: @other, name: "P4 reports outsider",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @bank = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Private GBP account",
      currency: "GBP", balance: 1500)
    @entry = @bank.entries.create!(entryable: Transaction.new,
      name: "Private course fee", amount: 80, currency: "GBP",
      date: Date.new(2025, 2, 10))
    @params = { scope: "personal", start_on: "2025-02-01",
      end_on: "2025-02-28", currency: "GBP", account_ids: [ @bank.id ] }
  end

  test "GET report reuses Sure facts, never mutates Entry, and rejects arbitrary filters" do
    path = "/api/v1/abroa/reports"
    get path, params: @params
    assert_response :unauthorized
    before = Entry.count
    get path, params: @params, headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "80.0", response.parsed_body.dig("data", "cash_flow", "net_consumption")
    assert response.parsed_body.dig("data", "cash_flow", "sure_income_statement")
    assert_equal before, Entry.count
    get path, params: @params.merge(skip_auth: "true"), headers: api_headers(@read_key)
    assert_response :unprocessable_entity
    get path, params: @params.merge(account_ids: [ SecureRandom.uuid ]),
      headers: api_headers(@read_key)
    assert_response :not_found
  end

  test "CSV export requires write permission and audit, download never returns direct blob links" do
    path = "/api/v1/abroa/report_exports"
    post path, params: @params.merge(format: "csv"), as: :json,
      headers: api_headers(@read_key).merge("Idempotency-Key" => "report-api")
    assert_response :forbidden
    post path, params: @params.merge(format: "csv"), as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "report-api")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    assert id
    assert_not_includes response.body, "blob"
    assert_not_includes response.body, "signed_id"
    get "/api/v1/abroa/report_exports/#{id}/download", headers: api_headers(@other_key)
    assert_response :not_found
    get "/api/v1/abroa/report_exports/#{id}/download", headers: api_headers(@read_key)
    assert_response :ok
    assert_includes response.media_type, "text/csv"
    assert_match(/attachment/i, response.headers["Content-Disposition"])
    assert_match(/no-store/, response.headers["Cache-Control"])
    assert_includes response.body, "net_consumption"
    assert Abroa::PlanningAuditEvent.where(
      event_type: "report_export.downloaded", resource_id: id).exists?
    post path, params: @params.merge(format: "csv"), as: :json,
      headers: api_headers(@student_key).merge("Idempotency-Key" => "report-api")
    assert_response :created
    assert_equal id, response.parsed_body.dig("data", "id")
    record = Abroa::ReportExport.find(id)
    record.update!(expires_at: 1.minute.ago)
    get "/api/v1/abroa/report_exports/#{id}/download", headers: api_headers(@read_key)
    assert_response :not_found
  end

  test "parent cannot choose short windows; revocation stops old exports" do
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @other, student_enabled: false, parent_enabled: true)
    project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Grant-scoped reporting", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "report-parent-project")
    Abroa::ProjectAccount.attach_for!(@student, project.id, @bank.id)
    Abroa::EntryAllocation.allocate_for!(@student, project.id,
      entry_id: @entry.id, amount: "80", key: "report-parent-entry")
    _invite, token = Abroa::RelationshipInvite.issue_for!(@other,
      recipient_email: @student.email, recipient_role: "student", key: "report-relation")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id,
      project_id: project.id, capability: "summary", key: "report-summary-grant")
    report_url = "/api/v1/abroa/parent/projects/#{project.id}/report"
    get report_url, params: { month: "2025-02" }, headers: api_headers(@other_key)
    assert_response :ok
    assert_equal true, response.parsed_body.dig("data", "project", "privacy_suppressed")
    assert_nil response.parsed_body.dig("data", "project", "net_consumption")
    get report_url, params: { start_on: "2025-02-01", end_on: "2025-02-02" },
      headers: api_headers(@other_key)
    assert_response :unprocessable_entity
    post "/api/v1/abroa/report_exports",
      params: { scope: "parent", project_id: project.id, month: "2025-02", format: "csv" },
      as: :json, headers: api_headers(@other_key).merge("Idempotency-Key" => "parent-report-csv")
    assert_response :created
    export_id = response.parsed_body.dig("data", "id")
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    get report_url, params: { month: "2025-02" }, headers: api_headers(@other_key)
    assert_response :not_found
    get "/api/v1/abroa/report_exports/#{export_id}/download",
      headers: api_headers(@other_key)
    assert_response :not_found
  end
end
