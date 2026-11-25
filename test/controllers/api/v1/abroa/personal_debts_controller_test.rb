require "test_helper"

class Api::V1::Abroa::PersonalDebtsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @student = users(:family_admin)
    @outsider = users(:empty)
    @key = ApiKey.create!(user: @student, name: "Debt operations",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @student, name: "Debt read",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @other_key = ApiKey.create!(user: @outsider, name: "Other person's key",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @bank = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Private GBP bank", currency: "GBP", balance: 2000)
    @entry = @bank.entries.create!(entryable: Transaction.new, name: "Shared expense",
      amount: 800, currency: "GBP", date: Date.new(2025, 2, 10))
    @payload = { kind: "paid_for_other", contact_nickname: "Alex", purpose: "Shared expense",
      source_entry_id: @entry.id, currency: "GBP", personal_amount: "200",
      other_amount: "600", incurred_on: "2025-02-10" }
  end

  test "create, index, show and settle a debt with real entry" do
    post base, params: @payload, as: :json
    assert_response :unauthorized
    post base, params: @payload, as: :json, headers: api_headers(@read_key).merge("Idempotency-Key" => "p4")
    assert_response :forbidden
    post base, params: @payload, as: :json, headers: api_headers(@key).merge("Idempotency-Key" => "p4")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    assert_equal "600.0", response.parsed_body.dig("data", "outstanding_amount")
    get base, headers: api_headers(@key)
    assert_response :ok
    assert_equal [ id ], response.parsed_body.fetch("data").map { |row| row.fetch("id") }
    get "#{base}/#{id}", headers: api_headers(@other_key)
    assert_response :not_found
    get "#{base}/#{id}", headers: api_headers(@read_key)
    assert_response :ok
    cash_entry = @bank.entries.create!(entryable: Transaction.new, name: "Debt settlement",
      amount: -200, currency: "GBP", date: Date.new(2025, 2, 12))
    path = "#{base}/#{id}/settlements"
    post path, params: { kind: "payment", entry_id: cash_entry.id, amount: "200" },
      as: :json, headers: api_headers(@key).merge("Idempotency-Key" => "settle")
    assert_response :created
    assert_equal "200.0", response.parsed_body.dig("data", "applied_amount")
    get "#{base}/#{id}", headers: api_headers(@key)
    assert_equal "400.0", response.parsed_body.dig("data", "outstanding_amount")
    get path, headers: api_headers(@other_key)
    assert_response :not_found
  end

  test "invalid parameters, unknown ownership and stale key cannot mutate" do
    post base, params: @payload.merge(currency: "BTC"), as: :json,
      headers: api_headers(@key).merge("Idempotency-Key" => "bad")
    assert_response :unprocessable_entity
    post base, params: @payload.merge(unexpected: "x"), as: :json,
      headers: api_headers(@key).merge("Idempotency-Key" => "bad-unknown")
    assert_response :unprocessable_entity
    post base, params: @payload, as: :json,
      headers: api_headers(@key).merge("Idempotency-Key" => "unique")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    post base, params: @payload.merge(purpose: "changed"), as: :json,
      headers: api_headers(@key).merge("Idempotency-Key" => "unique")
    assert_response :conflict
    post "#{base}/#{id}/cancel", params: { lock_version: 99 }, as: :json,
      headers: api_headers(@key)
    assert_response :conflict
    post "#{base}/#{id}/cancel", params: { lock_version: 0 }, as: :json,
      headers: api_headers(@other_key)
    assert_response :not_found
  end

  private
    def base
      "/api/v1/abroa/personal_debts"
    end
end
