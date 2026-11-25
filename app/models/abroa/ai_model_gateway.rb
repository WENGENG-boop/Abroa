require "net/http"
require "socket"
require "ipaddr"
require "json"
require "timeout"

module Abroa
  # Direct HTTPS, DNS-pinned transport for a user's OpenAI-compatible model.
  # Never follows 3xx and never trusts an env-configured proxy. All resolved
  # addresses are checked before a socket opens to prevent DNS rebinding.
  class AiModelGateway
    UnsafeEndpoint = Class.new(StandardError)
    ModelFailure = Class.new(StandardError)
    Timeout = Class.new(StandardError)
    MAX_REQUEST_BYTES = 8.megabytes
    MAX_MESSAGE_BYTES = 8.megabytes
    MAX_BODY_BYTES = 32.megabytes
    MAX_TEXT_BYTES = 16.megabytes

    BLOCKED_IPV4 = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8
      169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 192.0.2.0/24
      192.168.0.0/16 198.18.0.0/15 198.51.100.0/24
      203.0.113.0/24 224.0.0.0/4 240.0.0.0/4
    ].map { |block| IPAddr.new(block) }.freeze

    BLOCKED_IPV6 = %w[
      ::/128 ::1/128 ::ffff:0:0/96 64:ff9b::/96 100::/64
      2001::/32 2001:db8::/32 2002::/16 fc00::/7 fe80::/10 ff00::/8
    ].map { |block| IPAddr.new(block) }.freeze

    def self.validate_resolved_ips!(addresses)
      raise UnsafeEndpoint, "No DNS result" unless addresses.is_a?(Array) &&
        addresses.any? && addresses.size <= 32
      parsed = addresses.map do |raw|
        begin
          addr = IPAddr.new(raw)
          blocked = addr.ipv4? ? BLOCKED_IPV4 : BLOCKED_IPV6
          raise UnsafeEndpoint, "Private or reserved DNS answer" if
            blocked.any? { |network| network.include?(addr) }
          addr.to_s
        rescue IPAddr::InvalidAddressError
          raise UnsafeEndpoint, "Invalid DNS answer"
        end
      end
      parsed.uniq
    end

    def self.redirect_allowed?(_url)
      raise UnsafeEndpoint, "Redirects are disabled for user-selected AI endpoints"
    end

    def self.resolve_public_ips!(host, port)
      values = Socket.getaddrinfo(host, port, Socket::AF_UNSPEC,
        Socket::SOCK_STREAM).map { |row| row[3] }.uniq
      validate_resolved_ips!(values)
    rescue SocketError, IOError
      raise UnsafeEndpoint, "Endpoint DNS unavailable"
    end

    def self.chat(provider:, messages:)
      raise ActiveRecord::RecordNotFound unless provider && !provider.disabled?
      base = AiModelProvider.validated_url!(provider.base_url)
      raise ArgumentError, "Messages required" unless messages.is_a?(Array) &&
        messages.length.between?(1, 12) &&
        messages.all? { |row| row.is_a?(Hash) &&
          %w[system user assistant].include?(row[:role] || row["role"]) &&
          (row[:content] || row["content"]).is_a?(String) &&
          (row[:content] || row["content"]).bytesize.between?(1, MAX_MESSAGE_BYTES) }
      body_data = {
        model: provider.model_identifier,
        messages: messages,
        temperature: 0,
        max_tokens: provider.capabilities.fetch("max_output_tokens", AiModelProvider::DEFAULT_MAX_OUTPUT_TOKENS),
        stream: false
      }
      body = JSON.generate(body_data)
      raise ArgumentError, "Model request exceeds limit" if body.bytesize > MAX_REQUEST_BYTES
      uri = URI.parse(base)
      endpoint_path = (uri.path || "") + "/chat/completions"
      endpoint_path = endpoint_path.sub(%r{//+}, "/")
      ips = AiModelProvider.local_approved_url?(base) ? [ uri.host ] :
        resolve_public_ips!(uri.host, uri.port)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.ipaddr = ips.first # pins IP; TLS SNI/certificate still use original DNS name
      http.use_ssl = uri.scheme == "https"
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER if http.use_ssl?
      timeout = provider.capabilities.fetch("timeout_seconds", AiModelProvider::DEFAULT_TIMEOUT_SECONDS)
      http.open_timeout = [ timeout, 6 ].min
      http.read_timeout = timeout
      http.write_timeout = [ timeout, 6 ].min
      req = Net::HTTP::Post.new(endpoint_path)
      req["Content-Type"] = "application/json"
      req["Authorization"] = "Bearer #{provider.api_key}"
      req["Accept"] = "application/json"
      req.body = body
      res = nil
      response_body = +""
      http.request(req) do |response|
        res = response
        redirect_allowed?(response["location"]) if response.is_a?(Net::HTTPRedirection)
        response.read_body do |chunk|
          response_body << chunk
          raise ModelFailure, "Model response exceeds limit" if response_body.bytesize > MAX_BODY_BYTES
        end
      end
      raise ModelFailure, "Model returned unsuccessful status" unless res.is_a?(Net::HTTPSuccess)
      parsed = JSON.parse(response_body)
      raise ModelFailure, "Malformed model response" unless parsed.is_a?(Hash)
      choices = parsed["choices"]
      raise ModelFailure, "Malformed model choices" unless choices.is_a?(Array) &&
        choices.first.is_a?(Hash)
      first_choice = choices.first
      message = first_choice["message"]
      text = message["content"] if message.is_a?(Hash)
      raise ModelFailure, "Model response missing content" unless text.is_a?(String) &&
        text.bytesize.between?(1, MAX_TEXT_BYTES)
      usage = parsed["usage"]
      raise ModelFailure, "Malformed model usage" if usage && !usage.is_a?(Hash)
      info = usage || {}
      finish_reason = first_choice["finish_reason"]
      raise ModelFailure, "Unexpected model tool request" if
        %w[tool_calls function_call].include?(finish_reason)
      {
        text: text,
        input_tokens: valid_token_count(info["prompt_tokens"]),
        output_tokens: valid_token_count(info["completion_tokens"]),
        finish_reason: finish_reason,
        incomplete: finish_reason == "length",
        total_cost: nil, status: "success"
      }
    rescue Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error,
      Errno::ETIMEDOUT
      raise Timeout, "AI service timed out"
    rescue JSON::ParserError, OpenSSL::SSL::SSLError, EOFError, Errno::ECONNRESET,
      Errno::ECONNREFUSED, Errno::ECONNABORTED, Errno::EHOSTUNREACH,
      Errno::EPIPE, Net::HTTPBadResponse, Net::HTTPHeaderSyntaxError,
      SocketError, IOError
      raise ModelFailure, "AI service request failed"
    end

    def self.valid_token_count(value)
      value.is_a?(Integer) && value.between?(0, 100_000_000) ? value : nil
    end
  end
end
