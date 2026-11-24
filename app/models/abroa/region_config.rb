module Abroa
  class RegionConfig < ApplicationRecord
    self.table_name = "abroa_region_configs"
    validates :country_code, presence: true, uniqueness: true, length: { is: 2 }
    validate :valid_country_and_defaults

    def self.resolve(country_code)
      raise ArgumentError, "Invalid country code" unless country_code.is_a?(String) && country_code.match?(/\A[A-Za-z]{2}\z/)
      code = country_code.upcase
      country = ISO3166::Country.new(code)
      raise ArgumentError, "Unknown country" unless country

      config = find_by(country_code: code)
      values = config&.enabled? ? config.defaults : {}
      {
        country_code: code,
        currency: Family.normalize_currency_code(values["currency"] || country.currency_code),
        locale: config&.enabled? ? config.locale : nil,
        connection_kinds: [],
        configured: !!config&.enabled?
      }
    end

    private
      def valid_country_and_defaults
        unless country_code.is_a?(String) && country_code.match?(/\A[A-Z]{2}\z/) && ISO3166::Country.new(country_code)
          errors.add(:country_code, :invalid)
        end
        unless defaults.is_a?(Hash) && (defaults.keys - %w[currency]).empty?
          errors.add(:defaults, :invalid)
          return
        end
        if defaults.key?("currency") && !Family.normalize_currency_code(defaults["currency"])
          errors.add(:defaults, :invalid)
        end
      end
  end
end
