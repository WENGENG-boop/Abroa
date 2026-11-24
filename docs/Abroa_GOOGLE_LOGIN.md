# Abroa Google login

Use the existing Sure admin SSO provider or OIDC environment variables. For Abroa, prefer the OpenID Connect strategy with issuer https://accounts.google.com, scopes openid email profile, an OAuth web client and the exact HTTPS callback registered in Google Cloud. The original Google OAuth2 strategy is also supported using Google's trusted userinfo endpoint. No additional authentication framework is introduced.

The verified callback checks issuer (OIDC), stable subject and verified email before login or issuing pending-link state. The original account password/MFA linking path, one-time mobile linking code, unique provider/uid index and identity removal checks remain in place. New identities save the canonical issuer. A pre-existing Google identity lacking a trustworthy stored issuer is not silently reassigned; it requires a verified account recovery/linking procedure by the owner or authorized administrator. Other identity providers retain their existing behavior.

Google client credentials remain deployment-owned and are never committed. Real Google consent, redirect/state/nonce and token exchange require external configuration and live acceptance; mocked auth tests exercise the application's post-middleware behavior only.
