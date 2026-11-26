require "test_helper"
require "socket"
require "json"
require "rack/mock"

# Exercises the actual Net::HTTP transport against a real, deterministic
# loopback OpenAI-compatible endpoint in self-hosted mode. No external key,
# payment account or live AI model is used.
class Abroa::AiModelGatewayLocalEndpointTest < ActiveSupport::TestCase
  FAKE_KEY = "sk-local-acceptance-only".freeze

  test "approved local endpoint accepts a real HTTP chat completion with usage" do
    with_compatible_endpoint do |provider, receipts|
      result = Abroa::AiModelGateway.chat(provider: provider,
        messages: [ { role: "user", content: "Summarize a fake budget" } ])

      assert_equal "success", result[:status]
      assert_equal "Synthetic GBP budget: 1000.", result[:text]
      assert_equal 31, result[:input_tokens]
      assert_equal 18, result[:output_tokens]
      assert_equal false, result[:incomplete]
      request = receipts.pop
      assert_equal "/v1/chat/completions", request[:path]
      assert_equal "Bearer #{FAKE_KEY}", request[:headers]["authorization"]
      assert_equal "test-local-model", JSON.parse(request[:body]).fetch("model")
      assert_equal 16_384, JSON.parse(request[:body]).fetch("max_tokens")
    end
  end

  test "local upstream 401 is a generic safe failure, never a secret leak" do
    with_compatible_endpoint(status: 401,
      body: { error: { message: FAKE_KEY } }.to_json) do |provider, receipts|
      error = assert_raises(Abroa::AiModelGateway::ModelFailure) do
        Abroa::AiModelGateway.chat(provider: provider,
          messages: [ { role: "user", content: "fake" } ])
      end
      assert_not_includes error.message, FAKE_KEY
      assert_equal 401, receipts.pop[:response_status]
    end
  end

  test "local upstream 500 and 503 are safe model failures without credential disclosure" do
    [ 500, 503 ].each do |status|
      with_compatible_endpoint(status: status,
        body: { error: { message: FAKE_KEY } }.to_json) do |provider, receipts|
        error = assert_raises(Abroa::AiModelGateway::ModelFailure) do
          Abroa::AiModelGateway.chat(provider: provider,
            messages: [ { role: "user", content: "synthetic model outage" } ])
        end
        assert_not_includes error.message, FAKE_KEY
        assert_equal status, receipts.pop[:response_status]
      end
    end
  end

  test "local HTTP redirect to metadata endpoint is rejected, never followed" do
    with_compatible_endpoint(status: 302, location: "http://169.254.169.254/latest") do |provider, receipts|
      error = assert_raises(Abroa::AiModelGateway::UnsafeEndpoint) do
        Abroa::AiModelGateway.chat(provider: provider,
          messages: [ { role: "user", content: "fake" } ])
      end
      assert_match(/Redirects are disabled/, error.message)
      assert_equal "/v1/chat/completions", receipts.pop[:path]
    end
  end

  test "malformed local completion body does not escape as JSON parser exception" do
    with_compatible_endpoint(body: '{"choices":') do |provider, receipts|
      assert_raises(Abroa::AiModelGateway::ModelFailure) do
        Abroa::AiModelGateway.chat(provider: provider,
          messages: [ { role: "user", content: "fake" } ])
      end
      assert_equal 200, receipts.pop[:response_status]
    end
  end

  test "actual local HTTP length response is marked incomplete, not silently complete" do
    partial = completion_payload("partial synthetic answer", finish: "length")
    with_compatible_endpoint(body: partial) do |provider, receipts|
      result = Abroa::AiModelGateway.chat(provider: provider,
        messages: [ { role: "user", content: "fake" } ])
      assert_equal "partial synthetic answer", result[:text]
      assert_equal "length", result[:finish_reason]
      assert_equal true, result[:incomplete]
      assert_equal 18, result[:output_tokens]
      assert_equal 200, receipts.pop[:response_status]
    end
  end

  test "financial assistant calls real local model without writes or executable tools" do
    with_compatible_endpoint do |provider, receipts|
      student = users(:family_admin)
      project = Abroa::StudyProject.create_for!(student,
        attributes: { name: "Local A14 synthetic study", country: "GB", currency: "GBP",
          timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
        key: "a14-local-project")
      budget = Abroa::BudgetNode.create_for!(student, project.id,
        attributes: { name: "Local-only budget", currency: "GBP", limit_amount: "1000",
          start_on: "2025-01-01", end_on: "2028-12-31" }, key: "a14-local-budget")
      configured = Abroa::AiModelProvider.configure_for!(student,
        attributes: { base_url: provider.base_url, api_key: FAKE_KEY,
          model_name: provider.model_identifier }, key: "a14-local-model")
      assert_not_includes configured.encrypted_api_key, FAKE_KEY

      entries_before = Entry.count
      result = Abroa::AiFinancialAssistant.answer_for!(student,
        question: "Please change the balance or run a system command")
      assert_equal "success", result[:status]
      assert_equal "Synthetic GBP budget: 1000.", result[:text]
      assert_equal false, result[:incomplete]
      assert_equal 1, Abroa::AiModelUsage.for_user(student).count
      assert_equal entries_before, Entry.count
      assert_equal BigDecimal("1000"), budget.reload.limit_amount

      request = JSON.parse(receipts.pop[:body])
      assert_equal false, request.fetch("stream")
      assert_not request.key?("tools"), "Financial assistant must never expose executable model tools"
      assert_includes request.dig("messages", 0, "content"), "Do not execute financial actions"
      assert_includes request.dig("messages", 1, "content"), "current_budget_limits"
      assert_equal "test-local-model", request.fetch("model")
    end
  end

  test "API key authenticated chat reaches local compatible HTTP service without financial writes" do
    with_compatible_endpoint do |provider, receipts|
      student = users(:family_admin)
      Abroa::AiModelProvider.configure_for!(student,
        attributes: { base_url: provider.base_url, api_key: FAKE_KEY,
          model_name: provider.model_identifier }, key: "a14-local-api-model")
      key = ApiKey.create!(user: student, name: "A14 isolated API only",
        key: ApiKey.generate_secure_key, scopes: %w[read], source: "web")
      ledger_count = Entry.count
      app = Rack::MockRequest.new(Rails.application)
      response = app.post("/api/v1/abroa/ai/chat",
        "HTTP_HOST" => "localhost", "HTTP_X_API_KEY" => key.plain_key,
        "CONTENT_TYPE" => "application/json",
        :input => { question: "Explain this synthetic budget; do not execute" }.to_json)
      assert_equal 200, response.status
      parsed = JSON.parse(response.body)
      assert_equal "success", parsed.dig("data", "status")
      assert_equal "Synthetic GBP budget: 1000.", parsed.dig("data", "text")
      assert_equal false, parsed.dig("data", "incomplete")
      assert_equal ledger_count, Entry.count
      assert_not_includes response.body, FAKE_KEY
      assert_equal "Bearer #{FAKE_KEY}", receipts.pop[:headers]["authorization"]

      usage = app.get("/api/v1/abroa/ai/usage",
        "HTTP_HOST" => "localhost", "HTTP_X_API_KEY" => key.plain_key)
      assert_equal 200, usage.status
      assert_equal 1, JSON.parse(usage.body).dig("data", "calls")
    end
  end

  private
    def completion_payload(text, finish: "stop")
      { model: "test-local-model",
        choices: [ { index: 0, finish_reason: finish, message: { role: "assistant", content: text } } ],
        usage: { prompt_tokens: 31, completion_tokens: 18 } }.to_json
    end

    def with_compatible_endpoint(status: 200, body: nil, location: nil)
      listener = TCPServer.new("127.0.0.1", 0)
      port = listener.addr[1]
      endpoint = "http://127.0.0.1:#{port}/v1"
      receipts = Queue.new
      thread_failure = Queue.new
      payload = body || completion_payload("Synthetic GBP budget: 1000.")
      server = Thread.new do
        client = listener.accept
        begin
          first_line = client.gets
          raise "Missing request line" unless first_line
          headers = {}
          while (line = client.gets)
            break if line == "\r\n"
            name, value = line.split(":", 2)
            headers[name.downcase] = value.to_s.strip
          end
          request_body = client.read(Integer(headers.fetch("content-length")))
          receipts << { path: first_line.split[1], headers: headers,
            body: request_body, response_status: status }
          reason = { 200 => "OK", 302 => "Found", 401 => "Unauthorized",
            500 => "Internal Server Error", 503 => "Service Unavailable" }.fetch(status)
          output = "HTTP/1.1 #{status} #{reason}\r\n" \
            "Content-Type: application/json\r\n" \
            "Content-Length: #{payload.bytesize}\r\n" \
            "Connection: close\r\n"
          output += "Location: #{location}\r\n" if location
          client.write(output + "\r\n" + payload)
          client.flush
        ensure
          client.close
        end
      rescue IOError, SystemCallError => error
        thread_failure << error
      end

      old = ENV["ABROA_AI_ALLOWED_LOCAL_ENDPOINTS"]
      ENV["ABROA_AI_ALLOWED_LOCAL_ENDPOINTS"] = endpoint
      provider = Struct.new(:base_url, :model_identifier, :api_key, :capabilities) do
        def disabled?
          false
        end
      end.new(endpoint, "test-local-model", FAKE_KEY,
        Abroa::AiModelProvider.capabilities!({ timeout_seconds: 5 }))
      Rails.application.config.app_mode.stub(:self_hosted?, true) do
        assert_equal endpoint, Abroa::AiModelProvider.validated_url!(endpoint)
        yield provider, receipts
      end
      assert thread_failure.empty?, "Loopback server encountered a transport error"
    ensure
      ENV["ABROA_AI_ALLOWED_LOCAL_ENDPOINTS"] = old
      listener&.close
      server&.join(2)
      server&.kill if server&.alive?
    end
end
