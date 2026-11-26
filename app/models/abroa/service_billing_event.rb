class Abroa::ServiceBillingEvent < ApplicationRecord
  self.table_name = "abroa_service_billing_events"

  KINDS = %w[order discount payment refund].freeze
  Conflict = Class.new(StandardError)

  belongs_to :user
  belongs_to :service_subscription, class_name: "Abroa::ServiceSubscription"

  validates :kind, inclusion: { in: KINDS }
  validates :external_id, :occurred_at, presence: true
  validates :external_id, length: { maximum: 128 }, uniqueness: { scope: :user_id }
  validates :status, inclusion: { in: %w[simulated] }
  validate :valid_scope_and_amount

  def self.simulate!(user:, subscription:, external_id:, kind:, occurred_at:,
    amount: nil, currency: nil)
    raise ArgumentError, "Invalid synthetic callback" unless
      user&.active? && subscription&.user_id == user.id &&
      KINDS.include?(kind) && external_id.is_a?(String) &&
      external_id.bytesize.between?(1, 128) &&
      occurred_at.respond_to?(:utc) && (amount.nil? == currency.nil?)
    raise ArgumentError, "Amounts cannot be fabricated" unless amount.nil? && currency.nil?

    transaction do
      # No payment provider is called. No balance or subscription status changes.
      user.lock!
      existing = find_by(user_id: user.id, external_id: external_id)
      if existing
        raise Conflict, "Different callback with the same event ID" unless
          existing.kind == kind && existing.occurred_at.to_i == occurred_at.to_i &&
          existing.service_subscription_id == subscription.id
        next existing
      end

      create!(user: user, service_subscription: subscription, external_id: external_id,
        kind: kind, status: "simulated", occurred_at: occurred_at,
        amount: nil, currency: nil)
    end
  end

  def readonly?
    persisted? || super
  end

  private

    def valid_scope_and_amount
      errors.add(:user, "invalid subscription owner") if
        service_subscription && user_id != service_subscription.user_id
      errors.add(:base, "Unknown payment amount must be null") if amount.nil? != currency.nil?
      errors.add(:amount, "must be nonnegative") if amount && amount < 0
      errors.add(:currency, "invalid currency") if currency && !currency.match?(/\A[A-Z]{3}\z/)
    end
end
