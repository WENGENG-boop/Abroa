class Abroa::ServiceSubscriptionEvent < ApplicationRecord
  self.table_name = "abroa_service_subscription_events"

  belongs_to :service_subscription, class_name: "Abroa::ServiceSubscription"

  validates :action, inclusion: { in: %w[created updated] }
  validates :after_status, :new_plan, :request_id, :occurred_at, presence: true

  def readonly?
    persisted? || super
  end

  def destroy
    raise ActiveRecord::ReadOnlyRecord, "Subscription history is append-only"
  end
end
