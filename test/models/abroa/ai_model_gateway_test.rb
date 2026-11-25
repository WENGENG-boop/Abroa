require "test_helper"
require "net/http"

class Abroa::AiModelGatewayTest < ActiveSupport::TestCase
  FakeHttp = Struct.new(:response, :error,
    :ipaddr, :use_ssl, :verify_mode, :open_timeout, :read_timeout, :write_timeout) do
    def use_ssl?
      !!use_ssl
    end

    def request(_request)
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

  def chat_with(fake_http)
    Abroa::AiModelGateway.stub(:resolve_public_ips!, [ "8.8.8.8" ]) do
      Net::HTTP.stub(:new, fake_http) do
        Abroa::AiModelGateway.chat(provider: provider,
          messages: [ { role: "user", content: "PONG" } ])
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
end
