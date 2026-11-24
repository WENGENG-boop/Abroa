require "test_helper"

class AbroaGoogleLoginTest < ActionDispatch::IntegrationTest
  setup do
    AuthConfig.stubs(:sso_providers).returns([
      { name: "openid_connect", strategy: "openid_connect", issuer: "https://accounts.google.com" }
    ])
  end

  teardown do
    OmniAuth.config.mock_auth[:openid_connect] = nil
  end

  test "unverified email and invalid issuer do not initiate linking" do
    [ { email_verified: false }, { iss: "https://other.example" }, { sub: "other" } ].each do |claims|
      mock_google(claims)
      assert_no_difference [ "User.count", "OidcIdentity.count", "Session.count" ] do
        get "/auth/openid_connect/callback"
      end
      assert_redirected_to new_session_path
    end
  end

  test "verified identity with existing email is not silently linked" do
    mock_google
    assert_no_difference [ "OidcIdentity.count", "Session.count" ] do
      get "/auth/openid_connect/callback"
    end
    assert_redirected_to link_oidc_account_path
  end

  test "existing verified identity with matching issuer signs in" do
    user = users(:family_admin)
    OidcIdentity.create!(user: user, provider: "openid_connect", uid: "abroa-google-subject", issuer: "https://accounts.google.com")
    mock_google
    assert_difference "Session.count", 1 do
      get "/auth/openid_connect/callback"
    end
    assert_redirected_to root_path
  end

  private
    def mock_google(overrides = {})
      email = users(:family_admin).email
      OmniAuth.config.mock_auth[:openid_connect] = OmniAuth::AuthHash.new(
        provider: "openid_connect", uid: "abroa-google-subject",
        info: { email: email, name: "Student" }, credentials: {},
        extra: { raw_info: { iss: "https://accounts.google.com", sub: "abroa-google-subject", email: email, email_verified: true }.merge(overrides) }
      )
    end
end
