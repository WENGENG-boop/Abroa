# frozen_string_literal: true

require 'swagger_helper'
require 'stringio'

RSpec.describe 'API V1 Abroa statement intake', type: :request do
  let(:family) { Family.create!(name: 'Abroa statement docs', currency: 'GBP', locale: 'en', date_format: '%Y-%m-%d') }
  let(:user) { family.users.create!(email: 'abroa-statement-docs@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin') }
  let(:api_key) { ApiKey.create!(user: user, name: 'Docs', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web') }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'Checking', currency: 'GBP', balance: 1000) }
  let(:statement) do
    input = "Date,Amount,Description\n2025-01-10,-12.50,Cafe\n"
    prepared = AccountStatement::PreparedUpload.new(content: input, filename: 'statement.csv',
      content_type: 'text/csv', byte_size: input.bytesize, checksum: Digest::MD5.base64digest(input),
      content_sha256: Digest::SHA256.hexdigest(input))
    AccountStatement.create_from_prepared_upload!(family: family, account: account, prepared_upload: prepared)
  end
  let(:id) { statement.id }
  let(:input) do
    { source_kind: 'generic_csv', mapping: { date: 'Date', amount: 'Amount', description: 'Description',
      date_format: '%Y-%m-%d', signage: 'inflows_positive' } }
  end
  let(:preview) { Abroa::StatementIntake.preview_for!(user, statement_id: statement.id, **input) }
  let(:publish_input) { input.merge(preview_digest: preview.fetch(:preview_digest)) }

  path '/api/v1/abroa/imports/{id}/preview' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Preview a stored statement without ledger changes' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaIntakeInput' }
      response '200', 'Preview digest, bounded sample and row errors' do
        schema '$ref' => '#/components/schemas/AbroaIntakePreviewResponse'
        let(:body) { input }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/imports/{id}/publish' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Stage the confirmed preview into the review queue' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaIntakePublish' }
      response '201', 'Staging receipt (not posted to the ledger)' do
        schema '$ref' => '#/components/schemas/AbroaIntakeReceiptResponse'
        let(:body) { publish_input }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/imports/{id}/rollback' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Atomically reverse the batch without deleting shared or edited ledger entries' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Reversed receipt' do
        schema '$ref' => '#/components/schemas/AbroaIntakeReceiptResponse'
        let!(:receipt) { Abroa::StatementIntake.publish_for!(user, statement_id: statement.id, **publish_input) }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/imports/{id}' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get 'Read the staging receipt by Statement Vault id' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Staging receipt' do
        schema '$ref' => '#/components/schemas/AbroaIntakeReceiptResponse'
        let!(:receipt) { Abroa::StatementIntake.publish_for!(user, statement_id: statement.id, **publish_input) }
        run_test!
      end
    end
  end
end
