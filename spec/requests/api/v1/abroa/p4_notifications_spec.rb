require "swagger_helper"

RSpec.describe "API V1 Abroa notifications", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:body) { {} }

  path "/api/v1/abroa/notifications" do
    get "List private, currently authorized generic inbox notifications" do
      tags "Abroa P4 notifications"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :limit, in: :query, required: false, schema: { type: :integer }
      parameter name: :cursor, in: :query, required: false, schema: { type: :string }
      response "200", "Authenticated tenant-scoped inbox" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
    end
  end

  path "/api/v1/abroa/notifications/{id}/read" do
    parameter name: :id, in: :path, required: true, schema: { type: :string, format: :uuid }
    post "Mark a private notification read without exposing its source" do
      tags "Abroa P4 notifications"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Read state" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "403", "Write scope required" do
        schema type: :object, additionalProperties: true
      end
      response "404", "Not found or access withdrawn" do
        schema type: :object, additionalProperties: true
      end
    end
  end

  path "/api/v1/abroa/notification_preferences" do
    get "Read personal notification preferences" do
      tags "Abroa P4 notifications"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      response "200", "Preference snapshot" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
    end

    patch "Change opted-in channels and quiet hours with version guard" do
      tags "Abroa P4 notifications"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :body, in: :body, required: true,
        schema: { type: :object, additionalProperties: false,
          properties: { lock_version: { type: :integer }, email_enabled: { type: :boolean },
            in_app_enabled: { type: :boolean }, timezone: { type: :string },
            quiet_start_hour: { type: :integer }, quiet_end_hour: { type: :integer } },
          required: [ "lock_version" ] }
      response "200", "Updated preference version" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "403", "Write scope required" do
        schema type: :object, additionalProperties: true
      end
      response "409", "Preference version has changed" do
        schema type: :object, additionalProperties: true
      end
      response "422", "Unknown field or invalid timezone" do
        schema type: :object, additionalProperties: true
      end
    end
  end
end
