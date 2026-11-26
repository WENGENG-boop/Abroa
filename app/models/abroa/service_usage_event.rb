class Abroa::ServiceUsageEvent < ApplicationRecord
  self.table_name = "abroa_service_usage_events"

  belongs_to :user
  belongs_to :family

  validates :feature, inclusion: { in: Abroa::ServicePlan::ADD_ON_FEATURES }
  validates :source, :event_id, :occurred_at, :period_start, presence: true
  validates :event_id, length: { maximum: 128 }
  validates :source, length: { maximum: 40 }
  validates :quantity, numericality: { only_integer: true, greater_than: 0, less_than_or_equal_to: 1_000_000 }
  validates :event_id, uniqueness: { scope: %i[user_id feature] }
  validate :valid_tenant, :valid_cost

  def readonly?
    persisted? || super
  end

  private

    def valid_tenant
      errors.add(:family_id, "must match user family") unless user&.family_id == family_id
    end

    def valid_cost
      if cost_amount.nil? != cost_currency.nil?
        errors.add(:base, "Cost amount and currency must both be known or null")
      end
      if cost_amount && cost_amount < 0
        errors.add(:cost_amount, "must be nonnegative")
      end
    end
end
