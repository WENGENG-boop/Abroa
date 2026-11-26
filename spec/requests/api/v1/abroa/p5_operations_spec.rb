require "swagger_helper"

RSpec.describe "Abroa P5 platform operational APIs", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:body) { {} }

  {
    "/api/v1/abroa/platform/operations/users" => {
      get: "Registration, activity and seven-day retention with cohort denominators"
    },
    "/api/v1/abroa/platform/operations/banks" => {
      get: "Account sync outcomes, success denominator and configured region coverage"
    },
    "/api/v1/abroa/platform/operations/ai" => {
      get: "Aggregate model availability, calls and only known AI costs"
    },
    "/api/v1/abroa/platform/operations/imports" => {
      get: "Aggregate import outcomes and template version metadata without raw files"
    },
    "/api/v1/abroa/platform/operations/health" => {
      get: "Live safe DB, Redis, worker and scheduler probes"
    },
    "/api/v1/abroa/platform/operations/configs" => {
      get: "List bounded and allowlisted operational configuration",
      post: "System admin sets safe provider, region, model, import or policy metadata"
    },
    "/api/v1/abroa/platform/operations/configs/{id}" => {
      patch: "Optimistically update safe operational config with audit"
    },
    "/api/v1/abroa/platform/operations/governance" => {
      get: "Platform operator sees pseudonymous export and deletion request statuses"
    },
    "/api/v1/abroa/platform/operations/governance/{id}" => {
      patch: "System admin transitions governance status with verifiable completion evidence"
    },
    "/api/v1/abroa/governance/requests" => {
      get: "Current user lists their own export/deletion request status",
      post: "Current user submits an export or erasure request without disclosing private data"
    },
    "/api/v1/abroa/governance/requests/{id}" => {
      get: "Read only own governance request"
    }
  }.each do |route, methods|
    path route do
      if route.include?("{id}")
        parameter name: :id, in: :path, required: true,
          schema: { type: :string, format: :uuid }
      end

      methods.each do |method, description|
        send(method, description) do
          tags "Abroa P5 platform operations"
          consumes "application/json"
          produces "application/json"
          security [ { apiKeyAuth: [] } ]

          if method == :get && %w[users banks ai imports].any? { |suffix| route.end_with?("/#{suffix}") }
            parameter name: :from, in: :query, required: false,
              schema: { type: :string, format: :date }
            parameter name: :to, in: :query, required: false,
              schema: { type: :string, format: :date }
          end
          if method == :get && %w[configs governance requests].any? { |suffix| route.end_with?("/#{suffix}") }
            parameter name: :page, in: :query, required: false,
              schema: { type: :integer, minimum: 1, maximum: 1000 }
            parameter name: :limit, in: :query, required: false,
              schema: { type: :integer, minimum: 1, maximum: 100 }
          end
          if method.in?(%i[post patch])
            properties = if route.include?("/configs")
              {
                category: { type: :string }, code: { type: :string },
                settings: { type: :object, additionalProperties: false },
                version: { type: :integer, minimum: 0 }
              }
            elsif route.include?("/operations/governance")
              {
                status: { type: :string,
                  enum: %w[requested approved processing completed rejected failed] },
                version: { type: :integer, minimum: 0 },
                evidence_export_id: { type: :string, format: :uuid, nullable: true },
                reason_code: { type: :string, nullable: true }
              }
            else
              { kind: { type: :string, enum: %w[export deletion] } }
            end
            parameter name: :body, in: :body, required: true,
              schema: { type: :object, properties: properties, additionalProperties: false }
          end
          status = method == :post ? "201" : "200"
          response status, "Authorized and scope-filtered operation" do
            schema type: :object, additionalProperties: true
          end
          response "401", "Missing authentication" do
            schema type: :object, additionalProperties: true
            run_test!
          end
          response "403", "Platform permission or write scope missing" do
            schema type: :object, additionalProperties: true
          end
          response "404", "Unavailable or foreign governance request" do
            schema type: :object, additionalProperties: true
          end
          response "409", "Concurrent update or unverified export/deletion completion" do
            schema type: :object, additionalProperties: true
          end
          response "422", "Invalid time window, config or transition" do
            schema type: :object, additionalProperties: true
          end
        end
      end
    end
  end
end
