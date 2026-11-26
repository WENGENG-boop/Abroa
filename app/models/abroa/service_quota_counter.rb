class Abroa::ServiceQuotaCounter < ApplicationRecord
  self.table_name = "abroa_service_quota_counters"

  belongs_to :user

  validates :feature, inclusion: { in: Abroa::ServicePlan::ADD_ON_FEATURES }
  validates :used_count, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :period_start, presence: true
  validates :feature, uniqueness: { scope: %i[user_id period_start] }
end
