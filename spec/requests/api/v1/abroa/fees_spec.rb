require "swagger_helper"

RSpec.describe "API V1 Abroa study fees", type: :request do
  let(:family) { Family.create!(name: "Fee docs", currency: "GBP", locale: "en", date_format: "%Y-%m-%d") }
  let(:user) { family.users.create!(email: "study-fees-docs@example.com", password: "password123",
    password_confirmation: "password123", role: "admin") }
  let(:api_key) { ApiKey.create!(user: user, name: "Fee docs", key: ApiKey.generate_secure_key,
    scopes: %w[read_write], source: "web") }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:project) { Abroa::StudyProject.create_for!(user, attributes: {
    name: "Tuition docs", country: "GB", currency: "GBP", timezone: "Europe/London",
    start_on: "2025-01-01", end_on: "2026-12-31" }, key: "docs-fee-project") }
  let(:project_id) { project.id }
  let(:fields) { { name: "University tuition", kind: "tuition", currency: "GBP",
    gross_amount: "1000", discount_amount: "100" } }
  let(:fee) { Abroa::FeePlan.create_for!(user, project.id, attributes: fields, key: "docs-fee") }
  let(:fee_id) { fee.id }
  let(:installment_fields) { { name: "Autumn term", due_on: "2025-09-01",
    gross_amount: "1000", discount_amount: "100" } }
  let(:installment) { Abroa::FeeInstallment.schedule_for!(user, fee.id, attributes: installment_fields) }
  let(:installment_id) { installment.id }
  let(:account) { Account.create!(family: family, owner: user, accountable: Depository.new,
    name: "Fees docs cash", currency: "GBP", balance: 1000) }
  let(:entry) { account.entries.create!(entryable: Transaction.new, name: "University",
    currency: "GBP", amount: 100, date: Date.new(2025, 8, 1)) }
  let(:allocation) { Abroa::EntryAllocation.allocate_for!(user, project.id,
    entry_id: entry.id, amount: "100", key: "fee-docs-entry") }

  path "/api/v1/abroa/projects/{project_id}/fees" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List project tuition, housing, deposits and other scheduled fees" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Fees" do
        schema '$ref' => '#/components/schemas/AbroaFeePlanListResponse'
        run_test!
      end
    end
    post "Create a gross fee with directly deducted scholarships or discounts" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFeePlanCreate' }
      response "201", "Fee created without bank movement" do
        schema '$ref' => '#/components/schemas/AbroaFeePlanResponse'
        let(:'Idempotency-Key') { "docs-fee-new" }
        let(:body) { fields }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read an owned fee, plan total, paid amount and remaining liability" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      response "200", "Fee" do
        schema '$ref' => '#/components/schemas/AbroaFeePlanResponse'
        run_test!
      end
    end
    patch "Versioned fee edit, without altering the original ledger" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFeePlanUpdate' }
      response "200", "Updated" do
        schema '$ref' => '#/components/schemas/AbroaFeePlanResponse'
        let(:body) { { lock_version: fee.lock_version, name: "Updated tuition" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/import_recurring" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Import matching Sure bill occurrences once, without creating any bank transaction" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true, schema: {
        type: :object, required: %w[from_on through_on], additionalProperties: false,
        properties: {
          from_on: { type: :string, format: :date }, through_on: { type: :string, format: :date }
        }
      }
      response "200", "Bill occurrences linked as unique fee installments" do
        schema '$ref' => '#/components/schemas/AbroaFeeInstallmentImportResponse'
        let(:source) do
          RecurringTransaction.create!(family: family, account: account, name: "Recurring tuition",
            amount: 100, currency: "GBP", expected_day_of_month: 1,
            last_occurrence_date: Date.new(2025, 7, 1),
            next_expected_date: Date.new(2025, 8, 1), status: "inactive", occurrence_count: 0)
        end
        let(:fee) { Abroa::FeePlan.create_for!(user, project.id,
          attributes: fields.merge(recurring_transaction_id: source.id), key: "docs-fee-series") }
        let(:body) { { from_on: "2025-09-01", through_on: "2025-10-31" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/cancel" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Cancel an unpaid fee without deleting transactions" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaLockVersion' }
      response "200", "Cancelled" do
        schema '$ref' => '#/components/schemas/AbroaFeePlanResponse'
        let(:body) { { lock_version: fee.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/installments" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List fee installments" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      response "200", "Installments" do
        schema '$ref' => '#/components/schemas/AbroaFeeInstallmentListResponse'
        run_test!
      end
    end
    post "Create a dated installment of a net fee" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFeeInstallmentCreate' }
      response "201", "Installment created" do
        schema '$ref' => '#/components/schemas/AbroaFeeInstallmentResponse'
        let(:'Idempotency-Key') { "docs-fee-term" }
        let(:body) { installment_fields }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/installments/{installment_id}" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :installment_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read an installment and its confirmed payment state" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      response "200", "Installment" do
        schema '$ref' => '#/components/schemas/AbroaFeeInstallmentResponse'
        run_test!
      end
    end
    patch "Change due date or discount with optimistic locking" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFeeInstallmentUpdate' }
      response "200", "Updated installment" do
        schema '$ref' => '#/components/schemas/AbroaFeeInstallmentResponse'
        let(:body) { { name: "Revised term", lock_version: installment.lock_version } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/installments/{installment_id}/settlements" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :installment_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "List payment and refund links to real ledger entries" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      response "200", "Settlements" do
        schema '$ref' => '#/components/schemas/AbroaFeeSettlementListResponse'
        run_test!
      end
    end
    post "Reconcile a fee with confirmed entry allocation or authoritative refund link" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFeeSettlementCreate' }
      response "201", "Linked without creating another financial entry" do
        schema '$ref' => '#/components/schemas/AbroaFeeSettlementResponse'
        let(:'Idempotency-Key') { "docs-fee-payment" }
        let(:body) { { kind: "payment", allocation_id: allocation.id, amount: "100" } }
        run_test!
      end
    end
  end
end
