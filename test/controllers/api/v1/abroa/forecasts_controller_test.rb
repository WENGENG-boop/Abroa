require "test_helper"

class Api::V1::Abroa::ForecastsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    @student_key = ApiKey.create!(user: @student, name: "P4 forecast student",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @parent_key = ApiKey.create!(user: @parent, name: "P4 forecast parent",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @outsider_key = ApiKey.create!(user: @outsider, name: "P4 forecast outsider",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "P4 Forecast", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2028-12-31"
    }, key: "p4-forecast-test-project")
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Sensitive student GBP current account",
      currency: "GBP", balance: 1000)
    Abroa::ProjectAccount.attach_for!(@student, @project.id, @account.id)
    30.times do |i|
      @account.entries.create!(entryable: Transaction.new, name: "Student private spending",
        amount: 20, currency: "GBP", date: Date.current - i - 1)
    end
    _invite, token = Abroa::RelationshipInvite.issue_for!(@parent,
      recipient_email: @student.email, recipient_role: "student", key: "p4-forecast-relation")
    @relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    @grants = %w[summary forecasts_read account_balance fees_read].map do |capability|
      Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
        capability: capability, key: "p4-forecast-#{capability}")
    end
  end

  test "student API checks authentication and exposes reproducible 30 90 180 day forecast" do
    get "/api/v1/abroa/forecasts", params: { currency: "GBP", account_ids: [ @account.id ] }
    assert_response :unauthorized
    count = Entry.count
    get "/api/v1/abroa/forecasts",
      params: { currency: "GBP", account_ids: [ @account.id ] },
      headers: api_headers(@student_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "GBP", data["currency"]
    assert_equal "1000.0", data["opening_balance"]
    assert_equal "20.0", data["daily_consumption"]
    assert_equal "400.0", data.dig("balances", "day_30")
    assert_equal (Date.current + 51).iso8601, data["first_shortage_on"]
    assert_equal count, Entry.count
  end

  test "a parent receives only grant-filtered aggregate projection and revocation immediately blocks" do
    Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "paid_by_other", project_id: @project.id,
        contact_nickname: "Private confidential contact", purpose: "Private medical costs",
        currency: "GBP", personal_amount: "200", other_amount: "0",
        incurred_on: (Date.current - 5).iso8601, due_on: (Date.current + 10).iso8601 },
      key: "parent-excluded-private-debt")
    url = "/api/v1/abroa/parent/projects/#{@project.id}/forecast"
    get url, headers: api_headers(@parent_key)
    assert_response :ok
    data = response.parsed_body.fetch("data")
    assert_equal "GBP", data["currency"]
    assert_equal "800.0", data.dig("balances", "day_10"),
      "Private payable must not affect parent projection without a dedicated grant"
    assert_not_includes data.to_json, "Private confidential contact"
    assert_not_includes data.to_json, "Private medical costs"
    assert_not_includes data.to_json, @account.id
    assert_not_includes data.to_json, @account.name
    assert_not_includes data.to_json, "Student private spending"
    get url, headers: api_headers(@outsider_key)
    assert_response :not_found
    grant = @grants.find { |g| g.capability == "forecasts_read" }
    Abroa::Grant.revoke_for!(@student, @relation.id, grant.id, version: grant.lock_version)
    get url, headers: api_headers(@parent_key)
    assert_response :not_found
  end

  test "unrelated student accounts are not enumerated by guessed IDs" do
    get "/api/v1/abroa/forecasts",
      params: { currency: "GBP", account_ids: [ SecureRandom.uuid ] },
      headers: api_headers(@student_key)
    assert_response :not_found
  end

  test "unsupported scenario or other user's project is rejected" do
    get "/api/v1/abroa/forecasts", params: { scenario: "write-ledger", currency: "GBP" },
      headers: api_headers(@student_key)
    assert_response :unprocessable_entity
    get "/api/v1/abroa/forecasts", params: { project_id: SecureRandom.uuid, currency: "GBP" },
      headers: api_headers(@student_key)
    assert_response :not_found
  end
end
