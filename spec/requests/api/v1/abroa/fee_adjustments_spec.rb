require "swagger_helper"

RSpec.describe "API V1 Abroa fee adjustments", type: :request do
  let(:family) { Family.create!(name: "Adjustment docs", currency: "GBP", locale: "en", date_format: "%Y-%m-%d") }
  let(:user) { family.users.create!(email: "adjustments-docs@example.com", password: "password123",
    password_confirmation: "password123", role: "admin") }
  let(:api_key) { ApiKey.create!(user: user, name: "Fee adjustments docs",
    key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web") }
  let(:'X-Api-Key') { api_key.plain_key }
  let(:project) { Abroa::StudyProject.create_for!(user, attributes: {
    name: "Adjustment school", country: "GB", currency: "GBP", timezone: "Europe/London",
    start_on: "2025-01-01", end_on: "2027-12-31" }, key: "adjustment-docs-project") }
  let(:project_id) { project.id }
  let(:fee) { Abroa::FeePlan.create_for!(user, project.id, attributes: {
    name: "Tuition", kind: "tuition", currency: "GBP",
    gross_amount: "1000", discount_amount: "0" }, key: "adjustment-docs-fee") }
  let(:fee_id) { fee.id }

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/adjustments" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read durable fee waiver, scholarship offset and surcharge records" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Adjustments" do
        schema '$ref' => '#/components/schemas/AbroaFeeAdjustmentListResponse'
        run_test!
      end
    end
    post "Approve a liability-only adjustment, with no bank entry" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: "Idempotency-Key", in: :header, required: true, schema: { type: :string }
      parameter name: :body, in: :body, required: true, schema: { '$ref' => '#/components/schemas/AbroaFeeAdjustmentCreate' }
      response "201", "Adjustment recorded" do
        schema '$ref' => '#/components/schemas/AbroaFeeAdjustmentResponse'
        let(:'Idempotency-Key') { "adjustment-docs-create" }
        let(:body) { { kind: "waiver", amount: "100", reason: "Institutional waiver" } }
        run_test!
      end
    end
  end

  path "/api/v1/abroa/projects/{project_id}/fees/{fee_id}/adjustments/{id}/void" do
    parameter name: :project_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :fee_id, in: :path, required: true, schema: { type: :string, format: :uuid }
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Void an approved fee adjustment while keeping the audit record" do
      tags "Abroa study fees"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Voided" do
        schema '$ref' => '#/components/schemas/AbroaFeeAdjustmentResponse'
        let(:adjustment) { Abroa::FeeAdjustment.apply_for!(user, fee.id,
          kind: "waiver", amount: "100", reason: "Institutional waiver", key: "docs-void") }
        let(:id) { adjustment.id }
        run_test!
      end
    end
  end
end
