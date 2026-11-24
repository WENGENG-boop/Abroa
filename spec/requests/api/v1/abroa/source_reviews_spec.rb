# frozen_string_literal: true

require 'swagger_helper'

RSpec.describe 'API V1 Abroa source reviews and refunds', type: :request do
  let(:family) { Family.create!(name: 'Abroa import docs', currency: 'CNY', locale: 'en', date_format: '%Y-%m-%d') }
  let(:user) { family.users.create!(email: 'abroa-import-docs@example.com', password: 'password123', password_confirmation: 'password123', role: 'admin') }
  let(:api_key) { ApiKey.create!(user: user, name: 'Docs', key: ApiKey.generate_secure_key, scopes: %w[read_write], source: 'web') }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new, name: 'Checking', currency: 'CNY', balance: 1000) }
  let(:source) do
    row = Abroa::NormalizedSource.build(source_kind: 'generic_csv', source_instance_key: 'checking',
      source_row_key: 'docs:1', raw_digest: Digest::SHA256.hexdigest('docs:1'), local_date: Date.new(2025, 1, 10),
      amount: '100', currency: 'CNY', direction: 'outflow', provider_status: 'posted',
      transaction_kind: 'payment', description: 'Imported charge')
    Abroa::SourceRecord.ingest!(family: family, account: account, record: row)
  end
  let(:review) { Abroa::SourceReview.open_for!(user, source.id) }
  let(:original) { account.entries.create!(entryable: Transaction.new, name: 'Purchase', amount: 100, currency: 'CNY', date: Date.new(2025, 1, 10)) }
  let(:refund) { account.entries.create!(entryable: Transaction.new, name: 'Refund', amount: -30, currency: 'CNY', date: Date.new(2025, 2, 1)) }
  let(:refund_input) { { original_entry_id: original.id, refund_entry_id: refund.id, applied_amount: '30', refund_amount: '30' } }
  let(:refund_link) { Abroa::RefundLink.link_for!(user, **refund_input) }

  path '/api/v1/abroa/reviews' do
    get 'List reviews in accessible accounts' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      parameter name: :status, in: :query, schema: { type: :string, enum: %w[pending resolved dismissed] }
      parameter name: :page, in: :query, schema: { type: :integer, minimum: 1, maximum: 10000 }
      response '200', 'Paginated reviews' do
        schema type: :object, required: %w[data page has_more], properties: {
          data: { type: :array, items: { '$ref' => '#/components/schemas/AbroaSourceReview' } },
          page: { type: :integer }, has_more: { type: :boolean }
        }
        let!(:existing_review) { review }
        let(:status) { 'pending' }
        let(:page) { 1 }
        run_test!
      end
    end
    post 'Open a review for an assigned source' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false, required: %w[source_record_id],
        properties: { source_record_id: { type: :string, format: :uuid } }
      }
      response '201', 'Review created or reused' do
        schema type: :object, required: %w[data], properties: { data: { '$ref' => '#/components/schemas/AbroaSourceReview' } }
        let(:body) { { source_record_id: source.id } }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/reviews/{id}/resolve' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Resolve an import review' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: 'Idempotency-Key', in: :header, required: true, schema: { type: :string, maxLength: 128 }
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false, required: %w[resolution expected_version],
        properties: { resolution: { type: :string, enum: %w[create link ignore dismiss] },
          expected_version: { type: :integer, minimum: 0 }, target_entry_id: { type: :string, format: :uuid } }
      }
      response '200', 'Audited resolution' do
        schema '$ref' => '#/components/schemas/AbroaSourceActionResponse'
        let(:id) { review.id }
        let(:'Idempotency-Key') { 'docs-resolve' }
        let(:body) { { resolution: 'create', expected_version: review.lock_version } }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/source-actions/{id}/reverse' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post 'Reverse an unchanged source action' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Reversed or already reversed' do
        schema '$ref' => '#/components/schemas/AbroaSourceActionResponse'
        let(:id) { Abroa::SourceReview.resolve_for!(user, review_id: review.id, resolution: 'ignore', expected_version: review.lock_version, key: 'docs-ignore').id }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/refund-links' do
    post 'Allocate a real refund to a purchase' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      consumes 'application/json'
      produces 'application/json'
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, additionalProperties: false,
        required: %w[original_entry_id refund_entry_id applied_amount refund_amount],
        properties: {
          original_entry_id: { type: :string, format: :uuid }, refund_entry_id: { type: :string, format: :uuid },
          applied_amount: { type: :string }, refund_amount: { type: :string },
          rate_snapshot_id: { type: :string, format: :uuid, nullable: true }
        }
      }
      response '201', 'Refund allocated or replayed' do
        schema '$ref' => '#/components/schemas/AbroaRefundResponse'
        let(:body) { refund_input }
        run_test!
      end
    end
  end

  path '/api/v1/abroa/refund-links/{id}' do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    let(:id) { refund_link.id }
    get 'Read refund allocation' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Allocation' do
        schema '$ref' => '#/components/schemas/AbroaRefundResponse'
        run_test!
      end
    end
    delete 'Revoke allocation without removing either ledger entry' do
      tags 'Abroa imports'
      security [ { apiKeyAuth: [] } ]
      produces 'application/json'
      response '200', 'Revoked allocation' do
        schema '$ref' => '#/components/schemas/AbroaRefundResponse'
        run_test!
      end
    end
  end
end
