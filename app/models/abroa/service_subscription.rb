class Abroa::ServiceSubscription < ApplicationRecord
  self.table_name = "abroa_service_subscriptions"

  STATUSES = %w[active trialing paused canceled].freeze
  Conflict = Class.new(StandardError)
  Forbidden = Class.new(StandardError)

  belongs_to :user
  belongs_to :plan, class_name: "Abroa::ServicePlan"
  has_many :history, class_name: "Abroa::ServiceSubscriptionEvent",
    foreign_key: :service_subscription_id, dependent: :restrict_with_exception

  validates :status, inclusion: { in: STATUSES }
  validates :user_id, uniqueness: true
  validates :origin, inclusion: { in: %w[platform_admin simulation] }

  def self.current_for(user)
    return nil unless user&.persisted?
    find_by(user_id: user.id)
  end

  def self.active_for(user)
    subscription = current_for(user)
    return nil unless subscription && subscription.status.in?(%w[active trialing]) &&
      subscription.plan.enabled?
    return nil if subscription.ends_at && subscription.ends_at <= Time.current

    subscription
  end

  def self.assign!(user:, plan:, status:, actor:, version: nil, request_id: nil)
    raise Forbidden, "Platform billing permission required" unless
      Abroa::PlatformRoleAssignment.permitted?(actor, "operations.write")
    raise ArgumentError, "Plan must be configured" unless plan.is_a?(Abroa::ServicePlan) && plan.persisted? && plan.enabled?
    raise ArgumentError, "Invalid subscription status" unless STATUSES.include?(status)
    raise ArgumentError, "Target user unavailable" unless user&.active?
    if !version.nil? && (!version.is_a?(Integer) || version < 0)
      raise ArgumentError, "Invalid optimistic version"
    end

    transaction do
      # Serialize assignments and usage together using the same user row.
      user.lock!
      old = current_for(user)
      raise Conflict, "Subscription version mismatch" if old && !version.nil? && old.lock_version != version
      raise Conflict, "Subscription exists; version required" if old && version.nil?
      raise Conflict, "New subscription must use version zero" if !old && version && version != 0

      previous_status = old&.status
      previous_plan = old&.plan&.code
      instance = old || new(user: user)
      instance.plan = plan
      instance.status = status
      instance.origin = "platform_admin"
      instance.started_at ||= Time.current
      instance.ends_at = status == "canceled" ? Time.current : nil
      instance.save!

      Abroa::ServiceSubscriptionEvent.create!(
        service_subscription: instance, actor_user_id: actor.id,
        action: old ? "updated" : "created", before_status: previous_status,
        after_status: status, previous_plan: previous_plan, new_plan: plan.code,
        request_id: request_id.presence || SecureRandom.uuid,
        occurred_at: Time.current
      )
      instance
    end
  end

  def payload
    { id: id, status: status, plan: plan.payload, origin: origin,
      started_at: started_at, ends_at: ends_at, lock_version: lock_version }
  end
end
