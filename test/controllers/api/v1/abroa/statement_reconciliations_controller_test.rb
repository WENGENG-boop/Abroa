require "test_helper"

class Api::V1::Abroa::StatementReconciliationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Reconciliation API", currency: "GBP", balance: 100)
    content = "Date,Amount,Description\n2025-01-10,-12.50,Cafe\n"
    upload = AccountStatement::PreparedUpload.new(content: content, filename: "bank.csv",
      content_type: "text/csv", byte_size: content.bytesize, checksum: Digest::MD5.base64digest(content),
      content_sha256: Digest::SHA256.hexdigest(content))
    @statement = AccountStatement.create_from_prepared_upload!(family: @user.family, account: @account, prepared_upload: upload)
    day = Date.new(2025, 1, 10)
    @statement.update!(period_start_on: day, period_end_on: day, opening_balance: 100, closing_balance: 87.5, currency: "GBP")
    @account.balances.create!(date: day, currency: "GBP", balance: 87.5, cash_balance: 87.5,
      start_cash_balance: 100, cash_outflows: 12.5)
    config = { source_kind: "bank_statement", mapping: { date: "Date", amount: "Amount",
      description: "Description", date_format: "%Y-%m-%d", signage: "inflows_positive" } }
    preview = Abroa::StatementIntake.preview_for!(@user, statement_id: @statement.id, **config)
    Abroa::StatementIntake.publish_for!(@user, statement_id: @statement.id, preview_digest: preview.fetch(:preview_digest), **config)
    source = Abroa::SourceRecord.find_by!(statement: @statement)
    review = Abroa::SourceReview.find_by!(source_record: source)
    @entry = Abroa::SourceReview.resolve_for!(@user, review_id: review.id, resolution: "create",
      expected_version: review.lock_version, key: "reconciliation-api").entry
    @key = ApiKey.create!(user: @user, name: "Reconciliation write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Reconciliation read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @path = "/api/v1/abroa/imports/#{@statement.id}/reconciliation"
  end

  test "preview confirm and undo change only reconciliation markers" do
    assert_no_difference ["Entry.count", "Balance.count"] do
      post "#{@path}/preview", headers: api_headers(@key)
      assert_response :ok
      assert_equal "ready", response.parsed_body.dig("data", "status")
      digest = response.parsed_body.dig("data", "digest")
      assert_not @entry.reload.statement_reconciled?
      post "#{@path}/confirm", params: { digest: digest }, as: :json, headers: api_headers(@key)
      assert_response :ok
      assert_equal @statement.id, @entry.reload.reconciled_by_statement_id
      post "#{@path}/undo", headers: api_headers(@key)
      assert_response :ok
      assert_equal "reversed", response.parsed_body.dig("data", "status")
      assert_not @entry.reload.statement_reconciled?
      assert_equal BigDecimal("12.5"), @entry.amount
    end
  end

  test "reconciliation requires authentication and write scope and rejects stale digest" do
    post "#{@path}/preview"
    assert_response :unauthorized
    %w[preview confirm undo].each do |operation|
      post "#{@path}/#{operation}", headers: api_headers(@read_key)
      assert_response :forbidden
    end
    post "#{@path}/confirm", params: { digest: "invalid" }, as: :json, headers: api_headers(@key)
    assert_response :unprocessable_entity
    post "#{@path}/confirm", params: { digest: "a" * 64 }, as: :json, headers: api_headers(@key)
    assert_response :conflict
    assert_not @entry.reload.statement_reconciled?
  end

  test "another family cannot preview confirm or undo" do
    other = users(:empty)
    key = ApiKey.create!(user: other, name: "Other", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    %w[preview confirm undo].each do |operation|
      body = operation == "confirm" ? { digest: "a" * 64 } : {}
      post "#{@path}/#{operation}", params: body, as: :json, headers: api_headers(key)
      assert_response :not_found
    end
  end
end
