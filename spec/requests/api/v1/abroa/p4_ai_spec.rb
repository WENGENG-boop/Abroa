require "swagger_helper"

RSpec.describe "Abroa P4 AI financial assistant", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:body) { {} }
  let(:'Idempotency-Key') { "a14-openapi-idempotency" }

  {
    "/api/v1/abroa/ai/provider" => {
      get: "Read masked, user-owned AI model configuration",
      post: "Configure encrypted, allowlisted OpenAI-compatible AI model",
      patch: "Update model settings or disable AI using optimistic lock"
    },
    "/api/v1/abroa/ai/chat" => {
      post: "Read-only financial advice from authorized Sure/Abroa facts"
    },
    "/api/v1/abroa/ai/classify" => {
      post: "Generate a non-executing suggestion for an accessible posted entry"
    },
    "/api/v1/abroa/ai/usage" => {
      get: "Read current user's model usage, with unknown cost represented as null"
    },
    "/api/v1/abroa/ai/proposals" => {
      get: "List own proposed or audited AI financial actions",
      post: "Create an allowlisted financial operation proposal; returns one-time confirmation token"
    },
    "/api/v1/abroa/ai/proposals/{id}/confirm" => {
      post: "Explicit user approval with token, version and fresh resource evidence"
    },
    "/api/v1/abroa/ai/proposals/{id}/reject" => {
      post: "Reject an unconfirmed financial proposal"
    },
    "/api/v1/abroa/ai/proposals/{id}/execute" => {
      post: "Execute previously confirmed, still current P2 business action once"
    },
    "/api/v1/abroa/ai/proposals/{id}/compensate" => {
      post: "Compensate only when the executed resource was not changed again"
    }
  }.each do |route, methods|
    path route do
      if route.include?("{id}")
        parameter name: :id, in: :path, required: true,
          schema: { type: :string, format: :uuid }
      end
      methods.each do |http_method, description|
        send(http_method, description) do
          tags "Abroa P4 AI"
          security [ { apiKeyAuth: [] } ]
          consumes "application/json"
          produces "application/json"
          if http_method == :post && route.end_with?("/provider")
            parameter name: :'Idempotency-Key', in: :header, required: true,
              schema: { type: :string }
          end
          if http_method == :post && route.end_with?("/proposals")
            parameter name: :'Idempotency-Key', in: :header, required: true,
              schema: { type: :string }
          end
          if http_method.in?(%i[post patch])
            properties = if route == "/api/v1/abroa/ai/provider"
              {
                base_url: { type: :string, format: :uri },
                api_key: { type: :string, writeOnly: true },
                model_name: { type: :string },
                capabilities: { type: :object, additionalProperties: true },
                disabled: { type: :boolean },
                lock_version: { type: :integer }
              }
            elsif route == "/api/v1/abroa/ai/chat"
              { question: { type: :string }, project_id: { type: :string, format: :uuid },
                parent_project_id: { type: :string, format: :uuid } }
            elsif route == "/api/v1/abroa/ai/classify"
              { entry_id: { type: :string, format: :uuid } }
            elsif route.end_with?("/confirm")
              { token: { type: :string }, lock_version: { type: :integer } }
            elsif route.end_with?("/proposals")
              { operation: { type: :string, enum: %w[budget_update fee_adjust pool_allocate] },
                resource_id: { type: :string, format: :uuid },
                parameters: { type: :object, additionalProperties: true } }
            else
              {}
            end
            parameter name: :body, in: :body, required: true,
              schema: { type: :object, properties: properties, additionalProperties: false }
          end
          success_status = http_method == :post && route.end_with?("/provider") ||
            http_method == :post && route.end_with?("/proposals") ? "201" : "200"
          response success_status, "Authorized, scope-filtered response" do
            schema type: :object, additionalProperties: true
          end
          response "401", "Authentication required" do
            schema type: :object, additionalProperties: true
            run_test!
          end
          response "403", "Mutations require read/write permission" do
            schema type: :object, additionalProperties: true
          end
          response "404", "Foreign or revoked resource" do
            schema type: :object, additionalProperties: true
          end
          response "409", "Stale proposal, invalid confirmation or key replay conflict" do
            schema type: :object, additionalProperties: true
          end
          response "422", "Invalid URL, operation, argument or time bound" do
            schema type: :object, additionalProperties: true
          end
        end
      end
    end
  end
end
