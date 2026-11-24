require "test_helper"
require "stringio"

class Api::V1::Abroa::StatementIntakesControllerTest < ActionDispatch::IntegrationTest
  Upload = Struct.new(:original_filename, :content_type, :io) do
    def read(length)
      io.read(length)
    end

    def rewind
      io.rewind
    end
  end

  setup do
    @user = users(:family_admin)
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Statement API", currency: "GBP", balance: 100)
    upload = Upload.new("statement.csv", "text/csv",
      StringIO.new("Date,Amount,Description\n2025-01-10,-12.50,Cafe\n"))
    @statement = AccountStatement.create_from_upload!(family: @user.family, account: @account, file: upload)
    @key = ApiKey.create!(user: @user, name: "Statement write", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @read_key = ApiKey.create!(user: @user, name: "Statement read", key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @path = "/api/v1/abroa/imports/#{@statement.id}"
    @body = { source_kind: "generic_csv", mapping: { date: "Date", amount: "Amount",
      description: "Description", date_format: "%Y-%m-%d", signage: "inflows_positive" } }
  end

  test "preview and publish require write access and never directly create ledger entries" do
    post "#{@path}/preview", params: @body, as: :json, headers: api_headers(@read_key)
    assert_response :forbidden
    assert_no_difference [ "Abroa::SourceRecord.count", "Entry.count" ] do
      post "#{@path}/preview", params: @body, as: :json, headers: api_headers(@key)
      assert_response :ok
    end
    digest = response.parsed_body.dig("data", "preview_digest")
    assert digest.present?
    assert_no_difference "Entry.count" do
      assert_difference "Abroa::SourceRecord.count", 1 do
        post "#{@path}/publish", params: @body.merge(preview_digest: digest), as: :json, headers: api_headers(@key)
        assert_response :created
      end
      assert_no_difference "Abroa::SourceRecord.count" do
        post "#{@path}/publish", params: @body.merge(preview_digest: digest), as: :json, headers: api_headers(@key)
        assert_response :created
      end
    end
    get @path, headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "staged", response.parsed_body.dig("data", "status")
  end

  test "other tenant cannot read or stage private statement" do
    other = users(:empty)
    key = ApiKey.create!(user: other, name: "Other", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    get @path, headers: api_headers(key)
    assert_response :not_found
    post "#{@path}/preview", params: @body, as: :json, headers: api_headers(key)
    assert_response :not_found
  end
end
