class Abroa::ServiceEntitlements
  LimitExceeded = Class.new(StandardError)
  FeatureUnavailable = Class.new(StandardError)
  Conflict = Class.new(StandardError)

  # Canonical upstream sources. The event's logical ID, not the polling source,
  # is the idempotency identity: one AI request observed by two adapters counts once.
  SOURCE_FEATURES = {
    "abroa_ai" => %w[ai_calls ai_tokens],
    "sure_ai" => %w[ai_calls ai_tokens],
    "provider" => %w[bank_syncs],
    "import" => %w[import_parses],
    "ocr" => %w[managed_ocr]
  }.freeze

  def self.permitted?(user, feature)
    return false unless user&.active?
    return true if Abroa::ServicePlan::FREE_CORE.include?(feature.to_s)
    return false unless Abroa::ServicePlan::ADD_ON_FEATURES.include?(feature.to_s)
    return true if Rails.application.config.app_mode.self_hosted?

    subscription = Abroa::ServiceSubscription.active_for(user)
    subscription&.plan&.entitlement_for(feature).present? || false
  end

  def self.summary_for(user, at: Time.current)
    raise User::InactiveError unless user&.active?
    subscription = Abroa::ServiceSubscription.current_for(user)
    period = at.utc.beginning_of_month.to_date
    quotas = {}
    if !Rails.application.config.app_mode.self_hosted? &&
        (current = Abroa::ServiceSubscription.active_for(user))
      counters = Abroa::ServiceQuotaCounter.where(user_id: user.id, period_start: period)
        .pluck(:feature, :used_count).to_h
      current.plan.entitlements.each do |feature, rule|
        next unless rule.is_a?(Hash)
        used = counters.fetch(feature, 0)
        limit = rule.fetch("limit", nil)
        quotas[feature] = {
          used: used, limit: limit,
          remaining: limit.nil? ? nil : [ limit - used, 0 ].max,
          overage: !limit.nil? && used > limit,
          period_start: period
        }
      end
    end

    {
      mode: Rails.application.config.app_mode.self_hosted? ? "self_hosted" : "managed",
      always_free: Abroa::ServicePlan::FREE_CORE,
      subscription: {
        id: subscription&.id, plan: subscription&.plan&.code,
        status: subscription&.status || "none", version: subscription&.lock_version
      },
      quotas: quotas,
      period_start: period,
      cost_amount: nil,
      cost_currency: nil,
      cost_source: "unknown"
    }
  end

  def self.consume!(user:, feature:, source:, event_id:, quantity: 1,
    cost_amount: nil, cost_currency: nil)
    raise User::InactiveError unless user&.active?
    feature = feature.to_s
    source = source.to_s
    raise ArgumentError, "Unknown feature and usage source mapping" unless
      SOURCE_FEATURES.fetch(source, []).include?(feature)
    raise ArgumentError, "Invalid idempotency event" unless event_id.is_a?(String) &&
      event_id.bytesize.between?(1, 128) && !event_id.match?(/[\r\n\0]/)
    raise ArgumentError, "Invalid usage quantity" unless quantity.is_a?(Integer) &&
      quantity.between?(1, 1_000_000)
    raise ArgumentError, "Cost amount and currency must both be known or unknown" unless
      cost_amount.nil? == cost_currency.nil?

    Abroa::ServiceUsageEvent.transaction do
      # Serialize current-period entitlement changes, quota reservations and
      # dedupe using the same target user lock as subscription assignment.
      user.lock!
      raise User::InactiveError unless user.active?
      existing = Abroa::ServiceUsageEvent.find_by(
        user_id: user.id, feature: feature, event_id: event_id
      )
      if existing
        raise Conflict, "Replayed usage event has a conflicting payload" unless
          existing.quantity == quantity &&
          existing.cost_amount == cost_amount &&
          existing.cost_currency == cost_currency
        next existing
      end

      raise FeatureUnavailable, "Managed add-on is not enabled" unless permitted?(user, feature)

      period = Time.current.utc.beginning_of_month.to_date
      counter = Abroa::ServiceQuotaCounter.find_or_create_by!(
        user: user, feature: feature, period_start: period
      ) { |new_counter| new_counter.used_count = 0 }
      counter.lock!

      limit = if Rails.application.config.app_mode.self_hosted?
        nil
      else
        Abroa::ServiceSubscription.active_for(user)&.plan&.entitlement_for(feature)&.fetch("limit", nil)
      end

      raise LimitExceeded, "Configured monthly quota exceeded" if
        !limit.nil? && counter.used_count + quantity > limit

      event = Abroa::ServiceUsageEvent.create!(
        user: user, family: user.family,
        feature: feature, source: source, event_id: event_id,
        quantity: quantity, occurred_at: Time.current, period_start: period,
        cost_amount: cost_amount, cost_currency: cost_currency
      )
      counter.update!(used_count: counter.used_count + quantity)
      event
    end
  end
end
