require "timeout"

module Abroa
  module ProviderSyncStatus
    CODES = %w[unauthorized rate_limited timeout network_error provider_unavailable configuration_error failed].freeze
    module_function

    def code(error)
      return "timeout" if error.is_a?(Timeout::Error)
      return "network_error" if error.is_a?(SocketError) || error.is_a?(Errno::ECONNREFUSED) || error.is_a?(Errno::ECONNRESET)

      failure = error.respond_to?(:failure_code) ? error.failure_code.to_s : nil
      case failure
      when "unauthorized", "access_forbidden" then return "unauthorized"
      when "rate_limited" then return "rate_limited"
      when "timeout" then return "timeout"
      when "network_error", "unreachable" then return "network_error"
      when "server_error" then return "provider_unavailable"
      when "configuration_error", "invalid_url" then return "configuration_error"
      end

      status = [ :http_status, :status_code, :http_status_code ].filter_map do |field|
        error.public_send(field) if error.respond_to?(field)
      end.first.to_s
      case status
      when "401", "403" then "unauthorized"
      when "429" then "rate_limited"
      when "408", "504" then "timeout"
      when /\A5\d\d\z/ then "provider_unavailable"
      else "failed"
      end
    end
  end
end
