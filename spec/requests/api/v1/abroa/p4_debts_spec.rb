require "swagger_helper"

# Describes P4.1 endpoints. Security and financial behavior are Minitest's job.
RSpec.describe "API V1 Abroa personal debts", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:personal_debt_id) { SecureRandom.uuid }
  let(:body) { {} }
  let(:'X-Api-Key') { "" }
  let(:'Idempotency-Key') { "p4-debt-documentation-only" }

  {
    "/api/v1/abroa/personal_debts" => %i[get post],
    "/api/v1/abroa/personal_debts/{id}" => %i[get],
    "/api/v1/abroa/personal_debts/{id}/cancel" => %i[post],
    "/api/v1/abroa/personal_debts/{personal_debt_id}/settlements" => %i[get post]
  }.each do |url, verbs|
    path url do
      url.scan(/\{([^}]+)\}/).flatten.each do |name|
        parameter name: name.to_sym, in: :path, required: true,
          schema: { type: :string, format: :uuid }
      end
      verbs.each do |verb|
        public_send(verb, "P4 personal obligation #{verb.upcase} #{url}") do
          tags "Abroa P4 receivables"
          security [ { apiKeyAuth: [] } ]
          produces "application/json"
          if verb == :post
            consumes "application/json"
            parameter name: :body, in: :body, required: true,
              schema: { type: :object, additionalProperties: true }
            parameter name: :'Idempotency-Key', in: :header,
              required: false, schema: { type: :string }
          end
          response "401", "Authentication required" do
            schema type: :object, additionalProperties: true
            run_test!
          end
          response(verb == :post && !url.end_with?("/cancel") ? "201" : "200", "Authorized request") do
            schema type: :object, additionalProperties: true
          end
          response "403", "Insufficient scope" do
            schema type: :object, additionalProperties: true
          end
          response "404", "Missing or inaccessible" do
            schema type: :object, additionalProperties: true
          end
          response "409", "Idempotency/version conflict" do
            schema type: :object, additionalProperties: true
          end
          response "422", "Invalid input" do
            schema type: :object, additionalProperties: true
          end
        end
      end
    end
  end
end
