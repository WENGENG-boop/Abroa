require "swagger_helper"

RSpec.describe "API V1 Abroa fund pools", type: :request do
  let(:family) { Family.create!(name: "Pool docs", currency: "GBP", locale: "en", date_format: "%Y-%m-%d") }
  let(:user) { family.users.create!(email: "pools-docs@example.com", password: "password123",
    password_confirmation: "password123", role: "admin") }
  let(:api_key) { ApiKey.create!(user: user, name: "Pool docs key", key: ApiKey.generate_secure_key,
    scopes: %w[read_write], source: "web") }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:project) { Abroa::StudyProject.create_for!(user, attributes: {
    name: "Pool study", country: "GB", currency: "GBP", timezone: "Europe/London",
    start_on: "2025-01-01", end_on: "2027-12-31" }, key: "docs-pool-project") }
  let(:project_id) { project.id }
  let(:fields) { { name: "Tuition", kind: "tuition", currency: "GBP", target_amount: "10000" } }
  let(:pool) { Abroa::FundPool.create_for!(user, project.id, attributes: fields) }
  let(:id) { pool.id }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new,
    name: "Native pool money", currency: "GBP", balance: 100_000) }
  let(:account_id) { account.id }
  let(:pool_id) { pool.id }

  path "/api/v1/abroa/projects/{project_id}/pools" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List owned fund pools with native cash balances" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Pools" do
        schema '$ref' => '#/components/schemas/AbroaFundPoolListResponse'
        run_test!
      end
    end
    post "Create a virtual fund pool without moving real cash" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFundPoolCreate' }
      response "201", "Created" do
        schema '$ref' => '#/components/schemas/AbroaFundPoolResponse'
        let(:'Idempotency-Key') { "docs-fund-create" }
        let(:body) { fields }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/pools/{id}" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "View an owned virtual pool and its account allocation breakdown" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      response "200", "Pool" do
        schema '$ref' => '#/components/schemas/AbroaFundPoolResponse'
        run_test!
      end
    end
    patch "Update future target or metadata with a version" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFundPoolUpdate' }
      response "200", "Updated" do
        schema '$ref' => '#/components/schemas/AbroaFundPoolResponse'
        let(:body) { { lock_version: pool.lock_version, target_amount: "20000" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/pools/{id}/archive" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Archive a pool while retaining its promises" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaLockVersion' }
      response "200", "Archived" do
        schema '$ref' => '#/components/schemas/AbroaFundPoolResponse'
        let(:body) { { lock_version: pool.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/pools/{id}/restore" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Restore a virtual fund pool" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaLockVersion' }
      response "200", "Restored" do
        schema '$ref' => '#/components/schemas/AbroaFundPoolResponse'
        let(:archived) { Abroa::FundPool.archive_for!(user, pool.id, version: pool.lock_version) }
        let(:body) { { lock_version: archived.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/pools/cash/{account_id}" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :account_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read native-currency usable cash, Sure goals, pool pledges and shortfall" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      response "200", "Cash commitments" do
        schema '$ref' => '#/components/schemas/AbroaFundCashResponse'
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/pools/{pool_id}/movements" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :pool_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List immutable native-currency fund movements" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Fund movements" do
        schema '$ref' => '#/components/schemas/AbroaPoolMovementListResponse'
        run_test!
      end
    end
    post "Apply an idempotent virtual fund movement, optionally linked to a real ledger entry" do
      tags "Abroa planning"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaPoolMovementCreate' }
      response "201", "Recorded virtual movement" do
        schema '$ref' => '#/components/schemas/AbroaPoolMovementResponse'
        let(:'Idempotency-Key') { "docs-fund-allocate" }
        let(:body) { { account_id: account.id, kind: "allocate", amount: "1000" } }
        run_test!
      end
    end
  end
end
