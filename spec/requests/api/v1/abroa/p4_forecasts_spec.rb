require "swagger_helper"

RSpec.describe "API V1 Abroa forecasts", type: :request do
  let(:id) { SecureRandom.uuid }

  path "/api/v1/abroa/forecasts" do
    get "Read student-specific deterministic 30/90/180 day cash projections" do
      tags "Abroa P4 forecasts"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :project_id, in: :query, required: false, schema: { type: :string, format: :uuid }
      parameter name: :currency, in: :query, required: false, schema: { type: :string }
      parameter name: :scenario, in: :query, required: false,
        schema: { type: :string, enum: %w[conservative planned_funding stress] }
      response "200", "Deterministic projection, may be incomplete" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "404", "Unknown project or forbidden cash account" do
        schema type: :object, additionalProperties: true
      end
      response "422", "Invalid numeric or schedule input" do
        schema type: :object, additionalProperties: true
      end
    end
  end

  path "/api/v1/abroa/parent/projects/{id}/forecast" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    get "Read aggregate forecast only within active parental grants" do
      tags "Abroa P4 forecasts"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Grant-scoped financial projection" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "404", "Project or grant is not accessible" do
        schema type: :object, additionalProperties: true
      end
    end
  end
end
