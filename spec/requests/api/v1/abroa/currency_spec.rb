# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Abroa currency', type: :request do
  let(:family) { Family.create!(name: 'Abroa FX docs', currency: 'USD', locale: 'en', date_format: '%m-%d-%Y') }
  let(:user) { family.users.create!(email: 'abroa-fx-docs@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin') }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(user: user, name: 'API Docs Key', key: key, scopes: %w[read_write], source: 'web')
  end
  let(:'X-Api-Key') { api_key.plain_key }
  let(:source) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'CNY', currency: 'CNY', balance: 20_000) }
  let(:destination) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'GBP', currency: 'GBP', balance: 0) }
  let(:exchange_input) do
    { source_account_id: source.id, destination_account_id: destination.id, date: Date.current.iso8601,
      debit_amount: '9000', credit_amount: '1000', fee_amount: '100', fee_currency: 'CNY' }
  end

  path '/api/v1/abroa/fx/rates' do
    get 'Read a historical exchange rate' do
      tags 'Abroa FX'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :from, in: :query, required: true, schema: { type: :string }
      parameter name: :to, in: :query, required: true, schema: { type: :string }
      parameter name: :date, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :lookback_days, in: :query, schema: { type: :integer, minimum: 0, maximum: 365 }
      parameter name: :amount, in: :query, schema: { type: :string }
      response '200', 'Historical quote or incomplete rate' do
        schema '$ref' => '#/components/schemas/AbroaRateResponse'
        let(:from) { 'GBP' }
        let(:to) { 'GBP' }
        let(:date) { Date.current.iso8601 }
        let(:lookback_days) { 5 }
        let(:amount) { '100' }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/regions/{country_code}' do
    parameter name: :country_code, in: :path, required: true, schema: { type: :string }
    let(:country_code) { 'JP' }
    get 'Read country defaults (not a connectivity guarantee)' do
      tags 'Abroa FX'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Region defaults' do
        schema '$ref' => '#/components/schemas/AbroaRegionResponse'
        run_test!
      end
    end
  end

  path '/api/v1/abroa/accounts/{account_id}/profile' do
    parameter name: :account_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    let(:account_id) { source.id }
    get 'Read visible account region and wallet metadata' do
      tags 'Abroa FX'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Account profile' do
        schema '$ref' => '#/components/schemas/AbroaAccountProfileResponse'
        run_test!
      end
    end
    patch 'Update writable account metadata' do
      tags 'Abroa FX'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false, required: %w[lock_version],
        properties: {
          country: { type: :string, nullable: true }, wallet_kind: { type: :string, nullable: true, enum: [ 'alipay', 'wechat', 'other', nil ] },
          lock_version: { type: :integer, minimum: 0 }
        }
      }
      response '200', 'Updated' do
        schema '$ref' => '#/components/schemas/AbroaAccountProfileResponse'
        let(:body) { { country: 'CN', wallet_kind: 'alipay', lock_version: 0 } }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/fx/exchanges' do
    post 'Record an actual exchange, with separate fee' do
      tags 'Abroa FX'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: 'Idempotency-Key', in: :header, required: true, schema: { type: :string, maxLength: 128 }
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false,
        required: %w[source_account_id destination_account_id date debit_amount credit_amount],
        properties: {
          source_account_id: { type: :string, format: :uuid },
          destination_account_id: { type: :string, format: :uuid },
          date: { type: :string, format: :date },
          debit_amount: { type: :string, description: 'Source principal, excluding separate fee' },
          credit_amount: { type: :string, description: 'Destination principal, before a separately debited fee' },
          fee_amount: { type: :string }, fee_currency: { type: :string, nullable: true }
        }
      }
      response '201', 'Recorded or same-request replay' do
        schema '$ref' => '#/components/schemas/AbroaExchangeResponse'
        let(:'Idempotency-Key') { 'docs-fx-1' }
        let(:body) { exchange_input }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/fx/exchanges/{id}' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get 'Read actual exchange metadata and ledger consistency' do
      tags 'Abroa FX'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Exchange' do
        schema '$ref' => '#/components/schemas/AbroaExchangeResponse'
        let(:id) do
          Abroa::FxDetail.create_for!(user, **exchange_input.merge(date: Date.current, idempotency_key: 'docs-fx-read')).id
        end
        run_test!
      end
    end
  end
end
