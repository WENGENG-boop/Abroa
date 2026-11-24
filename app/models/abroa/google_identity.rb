module Abroa
  class GoogleIdentity
    Invalid = Class.new(StandardError)
    ISSUER = "https://accounts.google.com"
    ISSUERS = [ ISSUER, "accounts.google.com" ].freeze

    class << self
      def configuration(provider)
        AuthConfig.sso_providers.find do |config|
          name = config[:name] || config["name"] || config[:id] || config["id"]
          name.to_s == provider.to_s
        end
      end

      def google?(provider)
        config = configuration(provider)
        return false unless config

        strategy = config[:strategy] || config["strategy"]
        issuer = config[:issuer] || config["issuer"]
        strategy.to_s == "google_oauth2" ||
          (strategy.to_s == "openid_connect" && ISSUERS.include?(issuer))
      end

      # The auth hash must come from OmniAuth's server-side callback or from
      # the validated claims saved in its server-controlled linking state.
      # The native Google strategy uses Google's userinfo endpoint; the OIDC
      # strategy also verifies the configured issuer when exchanging the code.
      def claims!(auth)
        return unless google?(auth.provider)

        config = configuration(auth.provider)
        strategy = (config[:strategy] || config["strategy"]).to_s
        raw = auth.extra&.raw_info
        issuer = raw&.[]("iss")
        subject = raw&.[]("sub")
        email = raw&.[]("email")
        verified = raw&.[]("email_verified")
        if strategy == "google_oauth2" && issuer.nil?
          issuer = ISSUER
        end

        unless ISSUERS.include?(issuer) && subject.is_a?(String) && subject.present? &&
            subject == auth.uid && email.is_a?(String) && email.present? &&
            email.casecmp?(auth.info&.email.to_s) && verified == true
          raise Invalid, "Google identity claims are invalid"
        end

        { issuer: ISSUER, subject: subject, email_verified: true }
      end

      def valid_pending?(pending)
        data = pending.with_indifferent_access
        if google?(data[:provider])
          data[:issuer] == ISSUER && data[:email_verified] == true &&
            data[:subject].is_a?(String) && data[:subject].present? &&
            data[:subject] == data[:uid] && data[:email].is_a?(String) && data[:email].present?
        else
          # A provider changed after callback cannot consume Google linking state.
          !data.key?(:subject) && !data.key?(:email_verified)
        end
      end

      def matches?(identity, claims)
        if claims.nil?
          !ISSUERS.include?(identity.issuer)
        else
          ISSUERS.include?(identity.issuer) && identity.uid == claims[:subject]
        end
      end
    end
  end
end
