require "test_helper"

class Api::V1::Abroa::SourceReviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @key = ApiKey.create!(user: @user, name: "Review write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Review read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "API review account", currency: "CNY", balance: 1000)
    row = Abroa::NormalizedSource.build(source_kind: "generic_csv", source_instance_key: "checking",
      source_row_key: "api:1", raw_digest: Digest::SHA256.hexdigest("api:1"), local_date: Date.new(2025, 1, 10),
      amount: "100", currency: "CNY", direction: "outflow", provider_status: "posted",
      transaction_kind: "payment", description: "Imported charge")
    @source = Abroa::SourceRecord.ingest!(family: @user.family, account: @account, record: row)
  end

  test "review listing requires authentication and creation requires write scope" do
    get "/api/v1/abroa/reviews"
    assert_response :unauthorized
    post "/api/v1/abroa/reviews", params: { source_record_id: @source.id }, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    post "/api/v1/abroa/reviews", params: { source_record_id: @source.id }, as: :json, headers: api_headers(@key)
    assert_response :created
    review_id = response.parsed_body.dig("data", "id")
    get "/api/v1/abroa/reviews", headers: api_headers(@read_key)
    assert_response :ok
    assert_includes response.parsed_body.fetch("data").pluck("id"), review_id
  end

  test "resolution and reversal require write scope and are idempotent" do
    review = Abroa::SourceReview.open_for!(@user, @source.id)
    path = "/api/v1/abroa/reviews/#{review.id}/resolve"
    body = { resolution: "create", expected_version: review.lock_version }
    post path, params: body, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    headers = api_headers(@key).merge("Idempotency-Key" => "api-create")
    assert_difference "Entry.count", 1 do
      post path, params: body, as: :json, headers: headers
    end
    assert_response :ok
    action_id = response.parsed_body.dig("data", "id")
    assert_no_difference "Entry.count" do
      post path, params: body, as: :json, headers: headers
      assert_response :ok
      assert_equal action_id, response.parsed_body.dig("data", "id")
    end
    assert_difference "Entry.count", -1 do
      post "/api/v1/abroa/source-actions/#{action_id}/reverse", headers: api_headers(@key)
      assert_response :ok
    end
  end

  test "other tenant reviews are not returned or resolved" do
    outsider = users(:empty)
    other_key = ApiKey.create!(user: outsider, name: "Outsider", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    review = Abroa::SourceReview.open_for!(@user, @source.id)
    get "/api/v1/abroa/reviews", headers: api_headers(other_key)
    assert_response :ok
    assert_empty response.parsed_body.fetch("data")
    post "/api/v1/abroa/reviews/#{review.id}/resolve",
      params: { resolution: "create", expected_version: 0 }, as: :json,
      headers: api_headers(other_key).merge("Idempotency-Key" => "foreign")
    assert_response :not_found
  end

  test "refund allocation and revocation leave ledger unchanged" do
    original = @account.entries.create!(entryable: Transaction.new, name: "Purchase", amount: 100, currency: "CNY", date: Date.new(2025, 1, 10))
    refund = @account.entries.create!(entryable: Transaction.new, name: "Refund", amount: -30, currency: "CNY", date: Date.new(2025, 2, 1))
    body = { original_entry_id: original.id, refund_entry_id: refund.id, applied_amount: "30", refund_amount: "30" }
    assert_no_difference "Entry.count" do
      post "/api/v1/abroa/refund-links", params: body, as: :json, headers: api_headers(@key)
      assert_response :created
      id = response.parsed_body.dig("data", "id")
      get "/api/v1/abroa/refund-links/#{id}", headers: api_headers(@read_key)
      assert_response :ok
      delete "/api/v1/abroa/refund-links/#{id}", headers: api_headers(@key)
      assert_response :ok
      assert response.parsed_body.dig("data", "revoked_at").present?
    end
  end
end
