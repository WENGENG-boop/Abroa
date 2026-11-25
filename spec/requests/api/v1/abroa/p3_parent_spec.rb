require "swagger_helper"

# Documentation-only request specs. Positive behavior, tenant isolation, and
# financial state transitions are exercised in Minitest; these examples confirm
# that every P3 API operation enforces authentication before routing data.
RSpec.describe "API V1 Abroa P3 parent access and funding", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:relationship_id) { SecureRandom.uuid }
  let(:funding_plan_id) { SecureRandom.uuid }
  let(:funding_receipt_id) { SecureRandom.uuid }
  let(:body) { {} }
  let(:'X-Api-Key') { "" }
  let(:'Idempotency-Key') { "p3-documentation-only" }

  routes = {
    "/api/v1/abroa/relationship_invites" => %i[get post],
    "/api/v1/abroa/relationship_invites/{id}" => %i[get delete],
    "/api/v1/abroa/relationship_invites/accept" => %i[post],
    "/api/v1/abroa/relationship_invites/reject" => %i[post],
    "/api/v1/abroa/relationships" => %i[get],
    "/api/v1/abroa/relationships/{id}" => %i[get],
    "/api/v1/abroa/relationships/{id}/revoke" => %i[post],
    "/api/v1/abroa/relationships/{relationship_id}/grants" => %i[get post],
    "/api/v1/abroa/relationships/{relationship_id}/grants/{id}" => %i[delete],
    "/api/v1/abroa/parent/drafts" => %i[get post],
    "/api/v1/abroa/parent/drafts/{id}" => %i[get patch delete],
    "/api/v1/abroa/parent/budgets/{id}" => %i[patch],
    "/api/v1/abroa/proposals" => %i[get post],
    "/api/v1/abroa/proposals/{id}" => %i[get],
    "/api/v1/abroa/proposals/{id}/submit" => %i[post],
    "/api/v1/abroa/proposals/{id}/accept" => %i[post],
    "/api/v1/abroa/proposals/{id}/reject" => %i[post],
    "/api/v1/abroa/proposals/{id}/cancel" => %i[post],
    "/api/v1/abroa/funding_plans" => %i[get post],
    "/api/v1/abroa/funding_plans/{id}" => %i[get patch],
    "/api/v1/abroa/funding_plans/{id}/confirm" => %i[post],
    "/api/v1/abroa/funding_plans/{id}/reject" => %i[post],
    "/api/v1/abroa/funding_plans/{id}/cancel" => %i[post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/receipts" => %i[get post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/receipts/{id}" => %i[get],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/suggestions" => %i[get post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/suggestions/{id}/accept" => %i[post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/suggestions/{id}/reject" => %i[post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/suggestions/{id}/cancel" => %i[post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/notices" => %i[get post],
    "/api/v1/abroa/funding_plans/{funding_plan_id}/notices/{id}/revoke" => %i[post],
    "/api/v1/abroa/funding_receipts/{funding_receipt_id}/reversals" => %i[get post],
    "/api/v1/abroa/parent/projects" => %i[get],
    "/api/v1/abroa/parent/projects/{id}/summary" => %i[get],
    "/api/v1/abroa/parent/projects/{id}/budgets" => %i[get],
    "/api/v1/abroa/parent/projects/{id}/fees" => %i[get],
    "/api/v1/abroa/parent/projects/{id}/pools" => %i[get],
    "/api/v1/abroa/parent/projects/{id}/expenses" => %i[get],
    "/api/v1/abroa/parent/projects/{id}/funding" => %i[get]
  }.freeze

  routes.each do |url, methods|
    path url do
      url.scan(/\{([^}]+)\}/).flatten.each do |key|
        parameter name: key.to_sym, in: :path, required: true,
          schema: { type: :string, format: :uuid }
      end

      methods.each do |method|
        public_send(method, "P3 authenticated #{method.to_s.upcase} #{url}") do
          tags "Abroa P3 parent"
          security [ { apiKeyAuth: [] } ]
          produces "application/json"
          if %i[post patch delete].include?(method)
            consumes "application/json"
            parameter name: :body, in: :body, required: true,
              schema: { type: :object, additionalProperties: true }
          end
          response "401", "Missing API credential" do
            schema type: :object, additionalProperties: true
            run_test!
          end
          response(method == :post && !url.match?(%r{/(accept|reject|cancel|confirm|revoke|submit)\z}) ? "201" : "200",
            "Authorized request: see Abroa API contract and Minitest behavior tests") do
            schema type: :object, additionalProperties: true
          end
          response "403", "Insufficient API-key scope" do
            schema type: :object, additionalProperties: true
          end
          response "404", "No accessible resource" do
            schema type: :object, additionalProperties: true
          end
          response "409", "Version or state conflict" do
            schema type: :object, additionalProperties: true
          end
        end
      end
    end
  end
end
