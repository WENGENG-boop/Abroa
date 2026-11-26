require "test_helper"

class Api::V1::Abroa::AiControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:family_admin)
    @outsider = users(:empty)
    @read_key = ApiKey.create!(user: @user, name: "A14 read only",
      key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
    @write_key = ApiKey.create!(user: @user, name: "A14 writer",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @outsider_key = ApiKey.create!(user: @outsider, name: "A14 outsider",
      key: ApiKey.generate_secure_key, scopes: %w[read_write], source: "web")
    @project = Abroa::StudyProject.create_for!(@user,
      attributes: { name: "AI financial project", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "a14-api-project")
    @budget = Abroa::BudgetNode.create_for!(@user, @project.id,
      attributes: { name: "AI budget", currency: "GBP", limit_amount: "1000",
        start_on: "2025-01-01", end_on: "2028-12-31" }, key: "a14-api-budget")
    @config = { base_url: "https://api.example.com/v1",
      api_key: "sk-test-private-very-secret", model_name: "private-finance" }
  end

  test "AI model configuration requires write scope, masks secret and rejects SSRF" do
    get "/api/v1/abroa/ai/provider", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal false, response.parsed_body.dig("data", "configured")
    post "/api/v1/abroa/ai/provider", as: :json, params: @config,
      headers: api_headers(@read_key).merge("Idempotency-Key" => "a14-config")
    assert_response :forbidden
    post "/api/v1/abroa/ai/provider", as: :json, params: @config,
      headers: api_headers(@write_key).merge("Idempotency-Key" => "a14-config")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    assert id
    assert_not_includes response.body, "sk-test-private-very-secret"
    get "/api/v1/abroa/ai/provider", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal id, response.parsed_body.dig("data", "id")
    assert_not_includes response.body, "sk-test-private-very-secret"
    patch "/api/v1/abroa/ai/provider", as: :json,
      params: { base_url: "http://localhost:3000", lock_version: 0 },
      headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    assert_equal "https://api.example.com/v1", Abroa::AiModelProvider.for_user(@user).first.base_url
    patch "/api/v1/abroa/ai/provider", as: :json,
      params: { disabled: true, lock_version: 0 },
      headers: api_headers(@write_key)
    assert_response :ok
    assert_equal true, response.parsed_body.dig("data", "disabled")
  end

  test "custom model API accepts the model native 384K output ceiling" do
    post "/api/v1/abroa/ai/provider", as: :json,
      params: @config.merge(capabilities: {
        max_output_tokens: 393_216, timeout_seconds: 600,
        monthly_call_quota: 25, monthly_token_quota: 500_000
      }),
      headers: api_headers(@write_key).merge("Idempotency-Key" => "a14-high-output")
    assert_response :created
    assert_equal 393_216, response.parsed_body.dig("data", "capabilities", "max_output_tokens")
    assert_equal 600, response.parsed_body.dig("data", "capabilities", "timeout_seconds")
    assert_equal 25, response.parsed_body.dig("data", "capabilities", "monthly_call_quota")
    assert_not_includes response.body, @config.fetch(:api_key)
    get "/api/v1/abroa/ai/usage", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "user_configured", response.parsed_body.dig("data", "quota", "source")
    assert_equal 25, response.parsed_body.dig("data", "quota", "calls_remaining")
    assert_equal 500_000, response.parsed_body.dig("data", "quota", "tokens_remaining")

    patch "/api/v1/abroa/ai/provider", as: :json,
      params: { capabilities: { max_output_tokens: 393_217 }, lock_version: 0 },
      headers: api_headers(@write_key)
    assert_response :unprocessable_entity
    assert_equal 393_216, Abroa::AiModelProvider.for_user(@user).first.capabilities.fetch("max_output_tokens")
  end

  test "read-only AI chat cannot write ledger, usage counts expose unknown price as null" do
    post "/api/v1/abroa/ai/chat", as: :json,
      params: { question: "Can you explain my study budget?", project_id: @project.id },
      headers: api_headers(@read_key)
    assert_response :ok
    assert_equal "not_configured", response.parsed_body.dig("data", "status")
    Abroa::AiModelProvider.configure_for!(@user, attributes: @config, key: "a14-cfg-chat")
    old_entries = Entry.count
    responder = ->(provider:, messages:) do
      assert_equal @config[:api_key], provider.api_key
      assert_includes messages.to_json, "trusted_financial_facts"
      { status: "success", text: "This budget is 1000 GBP.", input_tokens: 42, output_tokens: 11,
        total_cost: nil }
    end
    Abroa::AiModelGateway.stub(:chat, responder) do
      post "/api/v1/abroa/ai/chat", as: :json,
        params: { question: "Can you explain the budget?", project_id: @project.id },
        headers: api_headers(@read_key)
    end
    assert_response :ok
    assert_equal "success", response.parsed_body.dig("data", "status")
    assert_equal old_entries, Entry.count
    get "/api/v1/abroa/ai/usage", headers: api_headers(@read_key)
    assert_response :ok
    assert_equal 1, response.parsed_body.dig("data", "calls")
    assert_equal 42, response.parsed_body.dig("data", "input_tokens")
    assert_nil response.parsed_body.dig("data", "cost_usd")
  end

  test "write proposal uses server-generated confirmation token, stale budgets and outsiders denied" do
    url = "/api/v1/abroa/ai/proposals"
    payload = { operation: "budget_update", resource_id: @budget.id,
      parameters: { limit_amount: "1250" } }
    post url, params: payload, as: :json,
      headers: api_headers(@read_key).merge("Idempotency-Key" => "proposal-ai")
    assert_response :forbidden
    post url, params: payload, as: :json,
      headers: api_headers(@write_key).merge("Idempotency-Key" => "proposal-ai")
    assert_response :created
    id = response.parsed_body.dig("data", "id")
    token = response.parsed_body.dig("confirmation_token")
    assert token
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
    post "#{url}/#{id}/execute", as: :json, params: {},
      headers: api_headers(@write_key)
    assert_response :conflict
    post "#{url}/#{id}/confirm", as: :json,
      params: { token: token, lock_version: 0 }, headers: api_headers(@outsider_key)
    assert_response :not_found
    post "#{url}/#{id}/confirm", as: :json,
      params: { token: token, lock_version: 0 }, headers: api_headers(@write_key)
    assert_response :ok
    post "#{url}/#{id}/execute", as: :json, params: {}, headers: api_headers(@write_key)
    assert_response :ok
    assert_equal BigDecimal("1250"), @budget.reload.limit_amount
    post "#{url}/#{id}/execute", as: :json, params: {}, headers: api_headers(@write_key)
    assert_response :ok
    assert_equal BigDecimal("1250"), @budget.reload.limit_amount
    post "#{url}/#{id}/compensate", as: :json, params: {}, headers: api_headers(@outsider_key)
    assert_response :not_found
    post "#{url}/#{id}/compensate", as: :json, params: {}, headers: api_headers(@write_key)
    assert_response :ok
    assert_equal BigDecimal("1000"), @budget.reload.limit_amount
    post url, params: payload, as: :json,
      headers: api_headers(@write_key).merge("Idempotency-Key" => "proposal-ai")
    assert_response :created
    assert_nil response.parsed_body["confirmation_token"]
  end
end
