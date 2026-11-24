# frozen_string_literal: true
require 'swagger_helper'

RSpec.describe 'API V1 Abroa funding account assignment', type: :request do
  let(:family) { Family.create!(name: 'Funding docs', currency: 'CNY', locale: 'en', date_format: '%Y-%m-%d') }
  let(:user) { family.users.create!(email: 'funding-docs@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin') }
  let(:api_key) { ApiKey.create!(user: user, name: 'Docs', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web') }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:bank) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'Bank', currency: 'CNY', balance: 1000) }
  let(:wallet) do
    account = Account.create!(family: family, owner: user, accountable: Depository.new, name: 'Wallet', currency: 'CNY', balance: 100)
    Abroa::AccountProfile.change_for!(user, account.id, wallet_kind: 'alipay')
    account
  end
  let(:statement) do
    csv = "交易时间,交易分类,交易对方,对方账号,商品说明,收/支,金额,收/付款方式,交易状态,交易订单号,商家订单号,备注\n2025-01-10 10:00:00,购物,商户,,商品,支出,10.00,现金,交易成功,docs-order,docs-ref,\n"
    upload = AccountStatement::PreparedUpload.new(content: csv, filename: 'wallet.csv', content_type: 'text/csv',
      byte_size: csv.bytesize, checksum: Digest::MD5.base64digest(csv), content_sha256: Digest::SHA256.hexdigest(csv))
    AccountStatement.create_from_prepared_upload!(family: family, account: bank, prepared_upload: upload)
  end
  let(:review) do
    preview = Abroa::StatementIntake.preview_for!(user, statement_id: statement.id, source_kind: 'alipay_statement')
    Abroa::StatementIntake.publish_for!(user, statement_id: statement.id, source_kind: 'alipay_statement',
      preview_digest: preview.fetch(:preview_digest))
    Abroa::SourceReview.find_by!(source_record: Abroa::SourceRecord.find_by!(statement: statement))
  end

  path '/api/v1/abroa/reviews/{id}/assign-account' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Confirm the actual funding account of an unresolved payment' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false, required: %w[account_id funding_kind expected_version],
        properties: { account_id: { type: :string, format: :uuid },
          funding_kind: { type: :string, enum: %w[wallet bank_account] },
          expected_version: { type: :integer, minimum: 0 } }
      }
      response '200', 'Assigned review; no ledger write' do
        schema type: :object, required: %w[data], properties: { data: { '$ref' => '#/components/schemas/AbroaSourceReview' } }
        let(:id) { review.id }
        let(:body) { { account_id: wallet.id, funding_kind: 'wallet', expected_version: review.lock_version } }
        run_test!
      end
    end
  end
end
