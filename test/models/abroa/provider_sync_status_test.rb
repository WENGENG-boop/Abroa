require "test_helper"

class Abroa::ProviderSyncStatusTest < ActiveSupport::TestCase
  test "classifies only structured provider error fields and typed network errors" do
    error_type = Class.new(StandardError) do
      attr_reader :http_status
      def initialize(status)
        @http_status = status
        super("contains private credential")
      end
    end
    assert_equal "unauthorized", Abroa::ProviderSyncStatus.code(error_type.new(401))
    assert_equal "rate_limited", Abroa::ProviderSyncStatus.code(error_type.new(429))
    assert_equal "provider_unavailable", Abroa::ProviderSyncStatus.code(error_type.new(503))
    assert_equal "timeout", Abroa::ProviderSyncStatus.code(Timeout::Error.new("secret"))
    assert_equal "failed", Abroa::ProviderSyncStatus.code(StandardError.new("HTTP 401 secret"))
  end
end
