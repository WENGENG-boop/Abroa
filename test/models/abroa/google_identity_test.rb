require "test_helper"

class Abroa::GoogleIdentityTest < ActiveSupport::TestCase
  setup do
    AuthConfig.stubs(:sso_providers).returns([
      { name: "campus_google", strategy: "openid_connect", issuer: "https://accounts.google.com" },
      { name: "native_google", strategy: "google_oauth2" },
      { name: "other", strategy: "openid_connect", issuer: "https://example.com" }
    ])
  end

  test "configured Google OIDC requires issuer subject and verified email" do
    claims = Abroa::GoogleIdentity.claims!(auth)
    assert_equal "https://accounts.google.com", claims[:issuer]
    assert_equal true, claims[:email_verified]

    [ { iss: "https://evil.example" }, { sub: "different" }, { email_verified: false },
      { email_verified: nil }, { email: "different@example.com" } ].each do |overrides|
      assert_raises(Abroa::GoogleIdentity::Invalid) { Abroa::GoogleIdentity.claims!(auth(overrides)) }
    end
  end

  test "native Google requires verified subject from userinfo not just email" do
    data = auth({ iss: nil }, provider: "native_google")
    assert_equal "https://accounts.google.com", Abroa::GoogleIdentity.claims!(data)[:issuer]
    assert_raises(Abroa::GoogleIdentity::Invalid) do
      Abroa::GoogleIdentity.claims!(auth({ sub: nil }, provider: "native_google"))
    end
  end

  test "other identity providers keep their original behavior" do
    assert_nil Abroa::GoogleIdentity.claims!(auth({ email_verified: false }, provider: "other"))
  end

  test "pending proof is bound to its provider and cannot be reused after configuration changes" do
    proof = Abroa::GoogleIdentity.claims!(auth).merge(provider: "campus_google", uid: "subject-1", email: "student@example.com")
    assert Abroa::GoogleIdentity.valid_pending?(proof)
    assert_not Abroa::GoogleIdentity.valid_pending?(proof.merge(email_verified: false))
    assert_not Abroa::GoogleIdentity.valid_pending?(proof.merge(subject: "other"))
    AuthConfig.stubs(:sso_providers).returns([ { name: "campus_google", strategy: "openid_connect", issuer: "https://other.example" } ])
    assert_not Abroa::GoogleIdentity.valid_pending?(proof)
  end

  test "stored Google issuer must match verified proof" do
    identity = OidcIdentity.new(provider: "campus_google", uid: "subject-1", issuer: "https://other.example")
    assert_not Abroa::GoogleIdentity.matches?(identity, Abroa::GoogleIdentity.claims!(auth))
    identity.issuer = nil
    assert_not Abroa::GoogleIdentity.matches?(identity, Abroa::GoogleIdentity.claims!(auth))
    identity.issuer = "https://accounts.google.com"
    assert Abroa::GoogleIdentity.matches?(identity, Abroa::GoogleIdentity.claims!(auth))
  end

  test "an existing Google identity cannot authenticate after provider is repointed" do
    identity = OidcIdentity.new(provider: "campus_google", uid: "subject-1", issuer: "https://accounts.google.com")
    AuthConfig.stubs(:sso_providers).returns([ { name: "campus_google", strategy: "openid_connect", issuer: "https://other.example" } ])
    assert_nil Abroa::GoogleIdentity.claims!(auth)
    assert_not Abroa::GoogleIdentity.matches?(identity, nil)
  end

  private
    def auth(overrides = {}, provider: "campus_google")
      raw = { iss: "https://accounts.google.com", sub: "subject-1", email: "student@example.com", email_verified: true }.merge(overrides)
      OmniAuth::AuthHash.new(provider: provider, uid: "subject-1",
        info: { email: "student@example.com" }, extra: { raw_info: raw })
    end
end
