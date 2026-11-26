class Abroa::ServicePlan < ApplicationRecord
  self.table_name = "abroa_service_plans"

  ADD_ON_FEATURES = %w[ai_calls ai_tokens bank_syncs import_parses managed_ocr].freeze
  FREE_CORE = %w[core_finance study_projects budgets fund_pools family_collaboration ledger
    parent_collaboration reports local_import].freeze

  validates :code, presence: true, uniqueness: true,
    format: { with: /\A[a-z][a-z0-9_-]{2,63}\z/ }
  validates :name, presence: true, length: { maximum: 120 }
  validate :valid_price_configuration, :valid_entitlement_configuration

  def entitlement_for(feature)
    entitlements.fetch(feature.to_s, nil)
  end

  def payload
    {
      id: id, code: code, name: name, enabled: enabled,
      entitlements: entitlements, price_amount: price_amount&.to_s("F"),
      price_currency: price_currency, lock_version: lock_version,
      created_at: created_at, updated_at: updated_at
    }
  end

  private

    def valid_price_configuration
      if price_amount.nil? != price_currency.nil?
        errors.add(:base, "Price amount and currency must both be configured or both be null")
      end
      if price_amount && (price_amount < 0 || price_amount > 1_000_000_000)
        errors.add(:price_amount, "out of range")
      end
      if price_currency && !price_currency.match?(/\A[A-Z]{3}\z/)
        errors.add(:price_currency, "invalid ISO currency")
      end
    end

    def valid_entitlement_configuration
      unless entitlements.is_a?(Hash) &&
          (entitlements.keys - ADD_ON_FEATURES).empty? &&
          entitlements.all? { |_feature, config| config.is_a?(Hash) &&
            (config.keys - %w[limit]).empty? && config.key?("limit") &&
            (config["limit"].nil? ||
              (config["limit"].is_a?(Integer) && config["limit"].between?(0, 100_000_000))) }
        errors.add(:entitlements, "must contain only permitted add-ons with explicit monthly limits")
      end
    end
end
