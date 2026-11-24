# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Abroa provider capture', type: :request do
  let(:family) { Family.create!(name: 'Abroa provider docs', currency: 'GBP', locale: 'en', date_format: '%Y-%m-%d') }
  let(:user) { family.users.create!(email: 'abroa-provider-docs@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin') }
  let(:api_key) { ApiKey.create!(user: user, name: 'Docs', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web') }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'Checking', currency: 'GBP', balance: 100) }
  let(:account_id) { account.id }

  path '/api/v1/abroa/accounts/{account_id}/sources/capture' do
    parameter name: :account_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Capture existing ledger provider evidence without posting new transactions' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false,
        properties: { limit: { type: :integer, minimum: 1, maximum: 500 },
          after_id: { type: :string, format: :uuid, nullable: true } }
      }
      response '200', 'Bounded capture result' do
        schema type: :object, required: %w[data], properties: {
          data: { type: :object, required: %w[account_id scanned_count captured_count conflict_count invalid_count next_cursor evidence_origin],
            properties: {
              account_id: { type: :string, format: :uuid }, scanned_count: { type: :integer },
              captured_count: { type: :integer }, conflict_count: { type: :integer },
              invalid_count: { type: :integer }, next_cursor: { type: :string, format: :uuid, nullable: true },
              evidence_origin: { type: :string, enum: %w[existing_ledger] }
            } }
        }
        let(:body) { { limit: 100 } }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/accounts/{account_id}/sources/diagnostics' do
    parameter name: :account_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get 'Read redacted account sync and source evidence status' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Diagnostics; not a live connectivity check' do
        schema type: :object, required: %w[data], properties: {
          data: { type: :object, required: %w[account_id configured_provider_count live_connection_status ledger_sync source_counts missing_ledger_count],
            properties: {
              account_id: { type: :string, format: :uuid }, configured_provider_count: { type: :integer },
              live_connection_status: { type: :string }, ledger_sync: { type: :object },
              source_counts: { type: :object, additionalProperties: { type: :integer } },
              missing_ledger_count: { type: :integer }
            } }
        }
        run_test!
      end
    end
  end
end
