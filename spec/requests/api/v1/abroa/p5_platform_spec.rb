require "swagger_helper"

RSpec.describe "Abroa P5 platform administration", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:body) { {} }

  {
    "/api/v1/abroa/platform/users" => {
      get: "List paginated user metadata without any financial balances or transactions"
    },
    "/api/v1/abroa/platform/users/{id}" => {
      get: "Read account status and public operational metadata only"
    },
    "/api/v1/abroa/platform/users/{id}/suspend" => {
      post: "Suspend account, revoke credentials and audit without deleting financial history"
    },
    "/api/v1/abroa/platform/users/{id}/unsuspend" => {
      post: "Restore account authentication eligibility but not revoked credentials"
    },
    "/api/v1/abroa/platform/roles" => {
      get: "List paginated platform RBAC assignments",
      post: "System administrator grants a platform-only role"
    },
    "/api/v1/abroa/platform/roles/{id}" => {
      delete: "System administrator revokes a platform-only role"
    }
  }.each do |route, methods|
    path route do
      if route.include?("{id}")
        parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
      end

      methods.each do |http_method, description|
        send(http_method, description) do
          tags "Abroa P5 platform administration"
          consumes "application/json"
          produces "application/json"
          security [ { apiKeyAuth: [] } ]

          if http_method == :get && route.end_with?("/users")
            parameter name: :limit, in: :query, required: false, schema: { type: :integer, minimum: 1, maximum: 100 }
            parameter name: :page, in: :query, required: false, schema: { type: :integer, minimum: 1, maximum: 1000 }
            parameter name: :status, in: :query, required: false, schema: { type: :string, enum: %w[active suspended inactive] }
            parameter name: :role, in: :query, required: false, schema: { type: :string, enum: %w[guest member admin super_admin] }
          end

          if http_method == :get && route.end_with?("/roles")
            parameter name: :limit, in: :query, required: false, schema: { type: :integer, minimum: 1, maximum: 100 }
            parameter name: :page, in: :query, required: false, schema: { type: :integer, minimum: 1, maximum: 1000 }
          end

          if http_method == :post
            properties = if route.end_with?("/suspend")
              {
                platform_access_version: { type: :integer, minimum: 0 },
                reason_code: { type: :string,
                  enum: %w[abuse_prevention compromised_account policy_violation user_request] }
              }
            elsif route.end_with?("/unsuspend")
              { platform_access_version: { type: :integer, minimum: 0 } }
            else
              {
                user_id: { type: :string, format: :uuid },
                role: { type: :string, enum: %w[operator access_admin system_admin] }
              }
            end
            parameter name: :body, in: :body, required: true,
              schema: { type: :object, additionalProperties: false, properties: properties }
          end

          response "200", "Scoped metadata or successful state transition" do
            schema type: :object, additionalProperties: true
          end
          response "201", "New platform role assignment" do
            schema type: :object, additionalProperties: true
          end
          response "401", "Missing or invalid credential" do
            schema type: :object, additionalProperties: true
            run_test!
          end
          response "403", "No independent platform permission" do
            schema type: :object, additionalProperties: true
          end
          response "404", "Unknown user or role assignment" do
            schema type: :object, additionalProperties: true
          end
          response "409", "Version conflict or last-admin safeguard" do
            schema type: :object, additionalProperties: true
          end
          response "422", "Invalid filter, role or suspension reason" do
            schema type: :object, additionalProperties: true
          end
        end
      end
    end
  end
end
