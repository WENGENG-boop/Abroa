require "swagger_helper"

RSpec.describe "Abroa P5 managed entitlements and simulated billing", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:user_id) { SecureRandom.uuid }
  let(:body) { {} }
  let(:user) { User.first }
  let(:api_key) do
    key = ApiKey.generate_secure_key
    ApiKey.create!(
      user: user, name: "API Docs Key",
      key: key, scopes: %w[read_write], source: "web"
    )
  end
  let(:'X-Api-Key') { api_key.plain_key }

  {
    "/api/v1/abroa/commercial/entitlements" => {
      get: "Current user core entitlements and add-on limits, with unknown costs null"
    },
    "/api/v1/abroa/commercial/usage" => {
      get: "Only current user usage events in an explicit bounded UTC period"
    },
    "/api/v1/abroa/commercial/plans" => {
      get: "Platform operator lists configured managed add-on plans",
      post: "System admin creates an unpriced-by-default add-on plan"
    },
    "/api/v1/abroa/commercial/plans/{id}" => {
      patch: "System admin optimistically updates plan with safe audit"
    },
    "/api/v1/abroa/commercial/subscriptions" => {
      get: "Platform operator lists paginated add-on subscriptions"
    },
    "/api/v1/abroa/commercial/subscriptions/{id}" => {
      get: "Platform operator reads one add-on subscription without financial ledger access"
    },
    "/api/v1/abroa/commercial/subscriptions/{user_id}" => {
      post: "System admin creates or changes a managed subscription with version check"
    },
    "/api/v1/abroa/commercial/billing/events" => {
      get: "Platform operator lists synthetic billing events without real payment credentials"
    },
    "/api/v1/abroa/commercial/billing/simulate" => {
      post: "Deterministic synthetic callback, amount unknown and no real charge"
    }
  }.each do |route, methods|
    path route do
      if route.include?("{id}")
        parameter name: :id, in: :path, required: true,
          schema: { type: :string, format: :uuid }
      end
      if route.include?("{user_id}")
        parameter name: :user_id, in: :path, required: true,
          schema: { type: :string, format: :uuid }
      end

      methods.each do |http_method, description|
        send(http_method, description) do
          tags "Abroa P5 managed commercial services"
          consumes "application/json"
          produces "application/json"
          security [ { apiKeyAuth: [] } ]

          if http_method == :get && route.end_with?("/usage")
            parameter name: :page, in: :query, required: false,
              schema: { type: :integer, minimum: 1, maximum: 1000 }
            parameter name: :limit, in: :query, required: false,
              schema: { type: :integer, minimum: 1, maximum: 100 }
            parameter name: :from, in: :query, required: false,
              schema: { type: :string, format: :date }
            parameter name: :to, in: :query, required: false,
              schema: { type: :string, format: :date }
            parameter name: :feature, in: :query, required: false,
              schema: { type: :string }
          end

          if http_method.in?(%i[post patch])
            properties = if route.end_with?("/plans") || route.include?("/plans/{id}")
              {
                code: { type: :string }, name: { type: :string },
                enabled: { type: :boolean }, version: { type: :integer },
                entitlements: { type: :object, additionalProperties: true },
                price_amount: { type: :string, nullable: true },
                price_currency: { type: :string, nullable: true }
              }
            elsif route.end_with?("/simulate")
              {
                user_id: { type: :string, format: :uuid },
                service_subscription_id: { type: :string, format: :uuid },
                external_id: { type: :string }, occurred_at: { type: :string, format: :date_time },
                kind: { type: :string, enum: %w[order discount payment refund] }
              }
            else
              {
                plan_id: { type: :string, format: :uuid },
                status: { type: :string, enum: %w[active trialing paused canceled] },
                version: { type: :integer, minimum: 0 }
              }
            end
            parameter name: :body, in: :body, required: true,
              schema: { type: :object, properties: properties, additionalProperties: false }
          end

          status_code = http_method == :post && route.end_with?("/plans") ? "201" : "200"
          response status_code, "Authorized, bounded response" do
            schema type: :object, additionalProperties: true
          end
          response "401", "Invalid or missing API credential" do
            schema type: :object, additionalProperties: true
            let(:'X-Api-Key') { "" }
            run_test!
          end
          response "403", "Not permitted for this identity, role, or write scope" do
            schema type: :object, additionalProperties: true
          end
          response "404", "Unavailable subscription, plan or identity" do
            schema type: :object, additionalProperties: true
          end
          response "409", "Stale plan, conflicting event or subscription version" do
            schema type: :object, additionalProperties: true
          end
          response "422", "Invalid entitlement, filter or synthetic event payload" do
            schema type: :object, additionalProperties: true
          end
        end
      end
    end
  end
end
