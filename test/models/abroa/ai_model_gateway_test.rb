require "test_helper"
require "net/http"

class Abroa::AiModelGatewayTest < ActiveSupport::TestCase
  FakeHttp = Struct.new(:response, :error,
    :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout,
    :last_request) do
    def use_ssl?
      !!use_ssl
    end

    def request(request)
      self.last_request = request
      raise error if error

      yield response
    end
  end

  def provider
    Struct.new(:base_url, :model_identifier, :api_key, :capabilities) do
      def disabled?
        false
      end
    end.new("https://api.example.com/v1", "test-model", "sk-test-only",
      { "timeout_seconds" => 10, "max_output_tokens" => 32 })
  end

  def chat_with(fake_http, selected_provider: provider, messages: [ { role: "user", content: "PONG" } ])
    Abroa::AiModelGateway.stub(:resolve_public_ips!, [ "8.8.8.8" ]) do
      Net::HTTP.stub(:new, fake_http) do
        Abroa::AiModelGateway.chat(provider: selected_provider, messages: messages)
      end
    end
  end

  def response_for(type, body)
    response = type.new("1.1", type == Net::HTTPOK ? "200" : "401",
      type == Net::HTTPOK ? "OK" : "Unauthorized")
    response.define_singleton_method(:read_body) { |&block| block.call(body) }
    response
  end

  test "gateway maps upstream 401 to a safe model error, not a constant NameError" do
    http = FakeHttp.new(response_for(Net::HTTPUnauthorized, '{"error":"invalid_api_key"}'))
    assert_raises(Abroa::AiModelGateway::ModelFailure) { chat_with(http) }
  end

  test "gateway maps upstream read timeout without leaking a NameError" do
    http = FakeHttp.new(nil, Net::ReadTimeout.new("simulated timeout"))
    assert_raises(Abroa::AiModelGateway::Timeout) { chat_with(http) }
  end

  test "gateway maps malformed upstream JSON to a safe model error" do
    http = FakeHttp.new(response_for(Net::HTTPOK, "{malformed"))
    assert_raises(Abroa::AiModelGateway::ModelFailure) { chat_with(http) }
  end

  test "gateway rejects valid JSON with unexpected response shapes as model failures" do
    malformed_shapes = [
      "null", "true", "123", %("text"), "[]", %({"choices":"PONG"}),
      %({"choices":[{"message":42}]}), %({"choices":[{"message":{"content":42}}]}),
      %({"choices":[{"message":{"content":"PONG"}}],"usage":"bad"})
    ]
    malformed_shapes.each do |body|
      http = FakeHttp.new(response_for(Net::HTTPOK, body))
      assert_raises(Abroa::AiModelGateway::ModelFailure, "Must reject #{body}") do
        chat_with(http)
      end
    end
  end

  test "gateway maps invalid HTTP framing and connection aborts to safe model failures" do
    [ Net::HTTPBadResponse.new("invalid response"), Errno::EHOSTUNREACH.new,
      Errno::ECONNABORTED.new, Errno::EPIPE.new ].each do |error|
      http = FakeHttp.new(nil, error)
      assert_raises(Abroa::AiModelGateway::ModelFailure) { chat_with(http) }
    end
  end

  test "gateway accepts a valid OpenAI compatible response" do
    payload = {
      choices: [ { message: { content: "PONG" } } ],
      usage: { prompt_tokens: 36, completion_tokens: 15 }
    }.to_json
    http = FakeHttp.new(response_for(Net::HTTPOK, payload))
    result = chat_with(http)
    assert_equal "success", result[:status]
    assert_equal "PONG", result[:text]
    assert_equal 36, result[:input_tokens]
    assert_equal 15, result[:output_tokens]
  end

  test "provider permits full 384K output budget and rejects values above model ceiling" do
    model = Abroa::AiModelProvider
    assert_equal 16_384, model.capabilities!({}).fetch("max_output_tokens")
    assert_equal 120, model.capabilities!({}).fetch("timeout_seconds")
    assert_equal 393_216, model.capabilities!({ max_output_tokens: 393_216 }).fetch("max_output_tokens")
    assert_equal 600, model.capabilities!({ timeout_seconds: 600 }).fetch("timeout_seconds")
    assert_raises(ArgumentError) { model.capabilities!({ max_output_tokens: 393_217 }) }
    assert_raises(ArgumentError) { model.capabilities!({ max_output_tokens: 16_384.5 }) }
    assert_raises(ArgumentError) { model.capabilities!({ timeout_seconds: 601 }) }
  end

  test "large max_tokens is forwarded verbatim with extended timeout" do
    details = {
      choices: [ { finish_reason: "stop", message: { content: "PONG" } } ],
      usage: { prompt_tokens: 30, completion_tokens: 10 }
    }.to_json
    http = FakeHttp.new(response_for(Net::HTTPOK, details))
    selected_provider = provider
    selected_provider.capabilities = {
      "max_output_tokens" => 393_216, "timeout_seconds" => 600
    }
    result = chat_with(http, selected_provider: selected_provider)
    assert_equal "PONG", result.fetch(:text)
    assert_equal 393_216, JSON.parse(http.last_request.body).fetch("max_tokens")
    assert_equal 600, http.read_timeout
  end

  test "long content and long input no longer hit legacy byte caps" do
    long_text = "x" * 2_200_000
    payload = {
      choices: [ { finish_reason: "stop", message: { content: long_text } } ],
      usage: { prompt_tokens: 30_000, completion_tokens: 200_000 }
    }.to_json
    http = FakeHttp.new(response_for(Net::HTTPOK, payload))
    result = chat_with(http, messages: [ { role: "user", content: "y" * 40_000 } ])
    assert_equal long_text.bytesize, result[:text].bytesize
    assert_equal 200_000, result[:output_tokens]
    assert_operator JSON.parse(http.last_request.body).dig("messages", 0, "content").bytesize, :>, 12_000
  end

  test "gateway explicitly marks provider length cutoff as incomplete" do
    payload = {
      choices: [ { finish_reason: "length", message: { content: "partial answer" } } ],
      usage: { prompt_tokens: 100, completion_tokens: 16_384 }
    }.to_json
    result = chat_with(FakeHttp.new(response_for(Net::HTTPOK, payload)))
    assert_equal "partial answer", result[:text]
    assert_equal "length", result[:finish_reason]
    assert_equal true, result[:incomplete]
    assert_equal "success", result[:status]
  end
end
