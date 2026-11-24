require "swagger_helper"

RSpec.describe "API V1 Abroa multi-level budgets", type: :request do
  let(:family) { Family.create!(name: "Budget docs", currency: "GBP", locale: "en", date_format: "%Y-%m-%d") }
  let(:user) { family.users.create!(email: "budget-docs@example.com", password: "password123", password_confirmation: "password123", role: "admin") }
  let(:api_key) { ApiKey.create!(user: user, name: "Budget docs key", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web") }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:project) { Abroa::StudyProject.create_for!(user, attributes: {
    name: "Budget study", country: "GB", currency: "GBP", timezone: "Europe/London",
    start_on: "2025-01-01", end_on: "2026-12-31" }, key: "docs-project-budget") }
  let(:project_id) { project.id }
  let(:fields) { { name: "Study year", start_on: "2025-01-01", end_on: "2025-12-31",
    currency: "GBP", limit_amount: "1000", rollover_enabled: true } }
  let(:budget) { Abroa::BudgetNode.create_for!(user, project.id, attributes: fields) }
  let(:id) { budget.id }

  path "/api/v1/abroa/projects/{project_id}/budgets" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List project budget nodes with pagination" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      produces "application/json"
      parameter name: :limit, in: :query, required: false, schema: { type: :integer }
      parameter name: :cursor, in: :query, required: false, schema: { type: :string }
      response "200", "Project budgets" do
        schema '$ref' => '#/components/schemas/AbroaBudgetListResponse'
        let(:limit) { 25 }
        let(:cursor) { nil }
        run_test!
      end
    end
    post "Create a budget node without writing to Sure's ledger" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      consumes "application/json"
      produces "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaBudgetCreate' }
      response "201", "Created" do
        schema '$ref' => '#/components/schemas/AbroaBudgetResponse'
        let(:'Idempotency-Key') { "docs-budget-new" }
        let(:body) { fields }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/budgets/{id}" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read an authorized budget node" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      response "200", "Budget" do
        schema '$ref' => '#/components/schemas/AbroaBudgetResponse'
        run_test!
      end
    end
    patch "Update budget attributes with optimistic version control" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaBudgetUpdate' }
      response "200", "Updated" do
        schema '$ref' => '#/components/schemas/AbroaBudgetResponse'
        let(:body) { { lock_version: budget.lock_version, limit_amount: "1200" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/budgets/{id}/execution" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read layered budget actual, committed and remaining amounts" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      response "200", "Budget execution" do
        schema '$ref' => '#/components/schemas/AbroaBudgetExecutionResponse'
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/budgets/{id}/versions" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read immutable budget change history" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      response "200", "Budget versions" do
        schema '$ref' => '#/components/schemas/AbroaBudgetVersionsResponse'
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/budgets/{id}/adjust" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Adjust a budget without changing past transactions" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, required: %w[lock_version], additionalProperties: false,
        properties: { limit_amount: { type: :string }, warning_threshold: { type: :string }, lock_version: { type: :integer } }
      }
      response "200", "Adjusted" do
        schema '$ref' => '#/components/schemas/AbroaBudgetResponse'
        let(:body) { { lock_version: budget.lock_version, limit_amount: "1500" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/budgets/{id}/rollover" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Apply remaining closed budget once to a compatible future period" do
      tags "Abroa planning"
      security [{ apiKeyAuth: [] }]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, required: %w[target_id], additionalProperties: false,
        properties: { target_id: { type: :string, format: :uuid } }
      }
      response "200", "Rolled over" do
        schema '$ref' => '#/components/schemas/AbroaBudgetResponse'
        let(:target) { Abroa::BudgetNode.create_for!(user, project.id,
          attributes: fields.merge(name: "Next year", start_on: "2026-01-01", end_on: "2026-12-31")) }
        let(:'Idempotency-Key') { "docs-rollover" }
        let(:body) { { target_id: target.id } }
        before { budget.update!(status: "closed") }
        run_test!
      end
    end
  end
end
