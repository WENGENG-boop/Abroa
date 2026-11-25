# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Abroa net consumption', type: :request do
  let(:family) { Family.create!(name: 'Consumption docs', currency: 'GBP', locale: 'en', date_format: '%Y-%m-%d') }
  let(:user) { family.users.create!(email: 'abroa-consumption-docs@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin') }
  let(:api_key) { ApiKey.create!(user: user, name: 'Read docs', key: ApiKey.generate_secure_key, scopes: %w[read], source: 'web') }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'Checking', currency: 'GBP', balance: 1000) }

  path '/api/v1/abroa/reports/consumption' do
    get 'Report gross and net standard spending with linked refunds at receipt date' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :start_on, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :end_on, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :currency, in: :query, required: true, schema: { type: :string }
      parameter name: :'account_ids[]', in: :query, required: false, schema: { type: :array, items: { type: :string, format: :uuid } }
      response '200', 'Consumption and refund projection' do
        schema '$ref' => '#/components/schemas/AbroaConsumptionResponse'
        let(:start_on) { '2025-01-01' }
        let(:end_on) { '2025-01-31' }
        let(:currency) { 'GBP' }
        let(:'account_ids[]') { [ account.id ] }
        run_test!
      end
    end
  end
end
