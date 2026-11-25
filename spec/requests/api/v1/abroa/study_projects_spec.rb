require "swagger_helper"

RSpec.describe "API V1 Abroa study projects", type: :request do
  let(:family) { Family.create!(name: "Study docs", currency: "GBP", locale: "en", date_format: "%Y-%m-%d") }
  let(:user) { family.users.create!(email: "study-docs@example.com", password: "password123", password_confirmation: "password123", role: "admin") }
  let(:api_key) { ApiKey.create!(user: user, name: "API Docs Key", key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web") }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:fields) { { name: "Study", country: "GB", currency: "GBP", timezone: "Europe/London", start_on: "2025-01-01", end_on: "2025-12-31" } }
  let(:project) { Abroa::StudyProject.create_for!(user, attributes: fields, key: "study-docs-main") }
  let(:id) { project.id }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new, name: "Study cash", currency: "GBP", balance: 1000) }
  let(:account_id) { account.id }
  let(:entry) { account.entries.create!(entryable: Transaction.new, name: "Expense", amount: 100, currency: "GBP", date: Date.new(2025, 3, 1)) }
  let(:period) { Abroa::StudyPeriod.create_for!(user, project.id, attributes: { name: "Year", kind: "year", start_on: "2025-01-01", end_on: "2025-12-31" }) }
  let(:period_id) { period.id }
  let(:allocation) { Abroa::EntryAllocation.allocate_for!(user, project.id, entry_id: entry.id, amount: "10") }
  let(:allocation_id) { allocation.id }
  let(:project_response) { { '$ref' => '#/components/schemas/AbroaStudyProjectResponse' } }
  let(:period_response) { { '$ref' => '#/components/schemas/AbroaStudyPeriodResponse' } }
  let(:allocation_response) { { '$ref' => '#/components/schemas/AbroaStudyAllocationResponse' } }
  let(:project_body) do
    { type: :object, required: %w[name country currency timezone start_on], additionalProperties: false,
      properties: {
        name: { type: :string }, country: { type: :string }, origin_country: { type: :string },
        city: { type: :string }, school: { type: :string }, timezone: { type: :string },
        start_on: { type: :string, format: :date }, end_on: { type: :string, format: :date },
        currency: { type: :string }
      } }
  end
  let(:period_body) do
    { type: :object, required: %w[name kind start_on end_on], additionalProperties: false,
      properties: {
        name: { type: :string }, kind: { type: :string, enum: %w[year term month custom] },
        start_on: { type: :string, format: :date }, end_on: { type: :string, format: :date },
        parent_id: { type: :string, format: :uuid, nullable: true }
      } }
  end

  path "/api/v1/abroa/projects" do
    get "List own study projects" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Own projects" do
        schema '$ref' => '#/components/schemas/AbroaStudyProjectListResponse'
        run_test!
      end
    end
    post "Create a study project with an idempotency key" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaStudyProjectCreate' }
      response "201", "Created" do
        schema '$ref' => '#/components/schemas/AbroaStudyProjectResponse'
        let(:'Idempotency-Key') { "study-docs-new" }
        let(:body) { fields }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read an owned study project" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Project" do
        schema '$ref' => '#/components/schemas/AbroaStudyProjectResponse'
        run_test!
      end
    end
    patch "Change project fields or state" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaStudyProjectUpdate' }
      response "200", "Updated" do
        schema '$ref' => '#/components/schemas/AbroaStudyProjectResponse'
        let(:body) { { name: "Updated project", lock_version: project.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/archive" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Archive project without modifying ledger facts" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: { type: :object, required: %w[lock_version], properties: { lock_version: { type: :integer } } }
      response "200", "Archived" do
        schema '$ref' => '#/components/schemas/AbroaStudyProjectResponse'
        let(:body) { { lock_version: project.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/restore" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Restore archived project state" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: { type: :object, required: %w[lock_version], properties: { lock_version: { type: :integer } } }
      response "200", "Restored" do
        schema '$ref' => '#/components/schemas/AbroaStudyProjectResponse'
        let(:archived) { Abroa::StudyProject.archive_for!(user, project.id, version: project.lock_version) }
        let(:body) { { lock_version: archived.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/summary" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Report project allocations without duplicating the personal ledger" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :start_on, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :end_on, in: :query, required: true, schema: { type: :string, format: :date }
      parameter name: :currency, in: :query, required: true, schema: { type: :string }
      response "200", "Project ledger projection" do
        schema '$ref' => '#/components/schemas/AbroaStudySummaryResponse'
        let(:start_on) { "2025-01-01" }
        let(:end_on) { "2025-12-31" }
        let(:currency) { "GBP" }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/periods" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List study periods" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Study periods" do
        schema '$ref' => '#/components/schemas/AbroaStudyPeriodListResponse'
        run_test!
      end
    end
    post "Add a study period" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaStudyPeriodCreate' }
      response "201", "Created" do
        schema '$ref' => '#/components/schemas/AbroaStudyPeriodResponse'
        let(:'Idempotency-Key') { "study-docs-period" }
        let(:body) { { name: "Year 1", kind: "year", start_on: "2025-01-01", end_on: "2025-12-31" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/periods/{period_id}" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :period_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read study period" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      response "200", "Period" do
        schema '$ref' => '#/components/schemas/AbroaStudyPeriodResponse'
        run_test!
      end
    end
    patch "Change study period" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaStudyPeriodUpdate' }
      response "200", "Updated" do
        schema '$ref' => '#/components/schemas/AbroaStudyPeriodResponse'
        let(:body) { { name: "Updated year", lock_version: period.lock_version } }
        run_test!
      end
    end
    delete "Remove an unreferenced study period" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { type: :object, required: %w[lock_version], properties: { lock_version: { type: :integer } } }
      response "200", "Deleted" do
        schema '$ref' => '#/components/schemas/AbroaStudyPeriodResponse'
        let(:body) { { lock_version: period.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/accounts" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List project linked accounts" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      response "200", "Account IDs" do
        schema '$ref' => '#/components/schemas/AbroaStudyAccountListResponse'
        run_test!
      end
    end
    post "Attach accessible account to project" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { type: :object, required: %w[account_id], properties: { account_id: { type: :string, format: :uuid } } }
      response "201", "Linked" do
        schema '$ref' => '#/components/schemas/AbroaStudyAccountResponse'
        let(:'Idempotency-Key') { "study-docs-account" }
        let(:body) { { account_id: account.id } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/accounts/{account_id}" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :account_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    delete "Unlink account without deleting its ledger" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      response "200", "Unlinked" do
        schema '$ref' => '#/components/schemas/AbroaStudyAccountResponse'
        before { Abroa::ProjectAccount.attach_for!(user, project.id, account.id) }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/allocations" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List explicit project ledger allocations" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      response "200", "Allocations" do
        schema '$ref' => '#/components/schemas/AbroaStudyAllocationListResponse'
        run_test!
      end
    end
    post "Allocate confirmed entry amount to project" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaStudyAllocationCreate' }
      response "201", "Allocated" do
        schema '$ref' => '#/components/schemas/AbroaStudyAllocationResponse'
        let(:'Idempotency-Key') { "study-docs-allocation" }
        let(:body) { { entry_id: entry.id, amount: "10" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{id}/allocations/{allocation_id}" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :allocation_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read explicit entry allocation" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      response "200", "Allocation" do
        schema '$ref' => '#/components/schemas/AbroaStudyAllocationResponse'
        run_test!
      end
    end
    patch "Change allocated amount with optimistic version" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaStudyAllocationUpdate' }
      response "200", "Updated" do
        schema '$ref' => '#/components/schemas/AbroaStudyAllocationResponse'
        let(:body) { { amount: "20", lock_version: allocation.lock_version } }
        run_test!
      end
    end
    delete "Release an allocation while retaining original ledger entry" do
      tags "Abroa study"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { type: :object, required: %w[lock_version], properties: { lock_version: { type: :integer } } }
      response "200", "Released" do
        schema '$ref' => '#/components/schemas/AbroaStudyAllocationResponse'
        let(:body) { { lock_version: allocation.lock_version } }
        run_test!
      end
    end
  end
end
