require "swagger_helper"

RSpec.describe "Abroa P4 financial reports and private exports", type: :request do
  let(:id) { SecureRandom.uuid }
  let(:body) { {} }
  let(:'Idempotency-Key') { "rswag-p4-export" }

  path "/api/v1/abroa/reports" do
    get "Read personal or study-project financial facts from Sure entries" do
      tags "Abroa P4 reports"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :scope, in: :query, required: true,
        schema: { type: :string, enum: %w[personal project] }
      parameter name: :project_id, in: :query, required: false,
        schema: { type: :string, format: :uuid }
      parameter name: :period_id, in: :query, required: false,
        schema: { type: :string, format: :uuid }
      parameter name: :start_on, in: :query, required: false,
        schema: { type: :string, format: :date }
      parameter name: :end_on, in: :query, required: false,
        schema: { type: :string, format: :date }
      parameter name: :currency, in: :query, required: false,
        schema: { type: :string }
      response "200", "Ledger-consistent financial statement with missing-data warnings" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "404", "Project/account not accessible" do
        schema type: :object, additionalProperties: true
      end
      response "422", "Invalid date, currency, or unsupported filter" do
        schema type: :object, additionalProperties: true
      end
    end
  end

  path "/api/v1/abroa/parent/projects/{id}/report" do
    parameter name: :id, in: :path, required: true,
      schema: { type: :string, format: :uuid }
    get "Read authorized, privacy-suppressed whole-month or academic-period report" do
      tags "Abroa P4 reports"
      security [ { apiKeyAuth: [] } ]
      produces "application/json"
      parameter name: :month, in: :query, required: false,
        schema: { type: :string, pattern: "^\\d{4}-(0[1-9]|1[0-2])$" }
      parameter name: :period_id, in: :query, required: false,
        schema: { type: :string, format: :uuid }
      response "200", "Grant-limited aggregate without private entry/account IDs" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "404", "Grant missing or withdrawn" do
        schema type: :object, additionalProperties: true
      end
      response "422", "Fine-grained or arbitrary parent filter refused" do
        schema type: :object, additionalProperties: true
      end
    end
  end

  path "/api/v1/abroa/report_exports" do
    post "Produce an expiring, private, audited CSV/JSON report snapshot" do
      tags "Abroa P4 reports"
      security [ { apiKeyAuth: [] } ]
      consumes "application/json"
      produces "application/json"
      parameter name: :'Idempotency-Key', in: :header, required: true,
        schema: { type: :string }
      parameter name: :body, in: :body, required: true,
        schema: { type: :object, additionalProperties: false,
          properties: {
            scope: { type: :string, enum: %w[personal project parent] },
            format: { type: :string, enum: %w[csv json] },
            project_id: { type: :string, format: :uuid },
            period_id: { type: :string, format: :uuid },
            start_on: { type: :string, format: :date },
            end_on: { type: :string, format: :date },
            month: { type: :string },
            currency: { type: :string },
            account_ids: { type: :array, items: { type: :string, format: :uuid } }
          }, required: %w[scope format] }
      response "201", "Private file created; only export ID returned" do
        schema type: :object, additionalProperties: true
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "403", "Read/write scope required" do
        schema type: :object, additionalProperties: true
      end
      response "409", "Idempotency key replay with changed filters" do
        schema type: :object, additionalProperties: true
      end
      response "422", "Invalid or incomplete export request" do
        schema type: :object, additionalProperties: true
      end
    end
  end

  path "/api/v1/abroa/report_exports/{id}/download" do
    parameter name: :id, in: :path, required: true,
      schema: { type: :string, format: :uuid }
    get "Download private blob with current access, integrity and expiry checks" do
      tags "Abroa P4 reports"
      security [ { apiKeyAuth: [] } ]
      produces "text/csv", "application/json"
      response "200", "Audited private attachment" do
        schema type: :string, format: :binary
      end
      response "401", "Authentication required" do
        schema type: :object, additionalProperties: true
        run_test!
      end
      response "404", "Not owner, access withdrawn or file expired" do
        schema type: :object, additionalProperties: true
      end
    end
  end
end
