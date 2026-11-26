class Api::V1::Abroa::ServiceEntitlementsController < Api::V1::Abroa::BaseController
  before_action :require_commercial_read!, only: %i[plans subscriptions subscription billing_events]
  before_action :require_commercial_write!, only: %i[create_plan update_plan assign_subscription simulate_billing]

  rescue_from Abroa::ServiceSubscription::Conflict,
    Abroa::ServiceEntitlements::Conflict,
    Abroa::ServiceBillingEvent::Conflict,
    ActiveRecord::StaleObjectError,
    with: :commercial_conflict
  rescue_from Abroa::ServiceSubscription::Forbidden, with: :commercial_forbidden
  rescue_from ArgumentError, with: :commercial_validation

  def entitlements
    render_json({ data: Abroa::ServiceEntitlements.summary_for(current_resource_owner) })
  end

  def usage
    page, limit = pagination
    feature = params[:feature]
    if feature.present? && !Abroa::ServicePlan::ADD_ON_FEATURES.include?(feature.to_s)
      raise ArgumentError, "Invalid usage feature"
    end
    window_start, window_end = date_window
    scope = Abroa::ServiceUsageEvent.where(user_id: current_resource_owner.id)
      .where(occurred_at: window_start...window_end)
      .order(occurred_at: :desc, id: :desc)
    scope = scope.where(feature: feature) if feature.present?
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({
      data: rows.first(limit).map do |entry|
        { id: entry.id, feature: entry.feature, source: entry.source,
          quantity: entry.quantity, occurred_at: entry.occurred_at,
          period_start: entry.period_start, cost_amount: entry.cost_amount&.to_s("F"),
          cost_currency: entry.cost_currency }
      end,
      meta: { page: page, limit: limit, next_page: rows.length > limit ? page + 1 : nil,
        window_start: window_start, window_end: window_end, source: "abroa_service_usage_events" }
    })
  end

  def plans
    page, limit = pagination
    rows = Abroa::ServicePlan.order(code: :asc, id: :asc)
      .offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({ data: rows.first(limit).map(&:payload),
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil } })
  end

  def create_plan
    return unless ensure_write_access
    fields = body_fields!(:code, :name, :entitlements, :enabled, :price_amount, :price_currency)
    plan = nil
    Abroa::ServicePlan.transaction do
      plan = Abroa::ServicePlan.create!(fields)
      audit!(target: current_resource_owner, action: "plan_create", outcome: "created",
        changes: { plan: plan.code, configured_fields: fields.keys.map(&:to_s).sort })
    end
    render_json({ data: plan.payload }, status: :created)
  end

  def update_plan
    return unless ensure_write_access
    fields = body_fields!(:version, :name, :entitlements, :enabled, :price_amount, :price_currency)
    version = strict_version(fields.delete(:version))
    plan = Abroa::ServicePlan.find(params[:id])
    Abroa::ServicePlan.transaction do
      plan.lock!
      raise Abroa::ServiceSubscription::Conflict unless plan.lock_version == version

      plan.update!(fields)
      audit!(target: current_resource_owner, action: "plan_update", outcome: "updated",
        changes: { plan: plan.code, version: plan.lock_version, configured_fields: fields.keys.map(&:to_s).sort })
    end
    render_json({ data: plan.payload })
  end

  def subscriptions
    page, limit = pagination
    scope = Abroa::ServiceSubscription.order(updated_at: :desc, id: :desc)
    if params[:user_id].present?
      raise ArgumentError, "Invalid user ID" unless valid_uuid?(params[:user_id])
      scope = scope.where(user_id: params[:user_id])
    end
    rows = scope.offset((page - 1) * limit).limit(limit + 1).includes(:plan).to_a
    render_json({ data: rows.first(limit).map { |row| subscription_payload(row) },
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil } })
  end

  def subscription
    render_json({ data: subscription_payload(Abroa::ServiceSubscription.find(params[:id])) })
  end

  def assign_subscription
    return unless ensure_write_access
    fields = body_fields!(:plan_id, :status, :version)
    raise ArgumentError, "Invalid plan or user ID" unless
      valid_uuid?(fields[:plan_id]) && valid_uuid?(params[:user_id])

    plan = Abroa::ServicePlan.find(fields.fetch(:plan_id))
    user = User.find(params[:user_id])
    version = fields.key?(:version) ? strict_version(fields.fetch(:version)) : nil
    subscription = nil
    Abroa::ServiceSubscription.transaction do
      subscription = Abroa::ServiceSubscription.assign!(
        user: user, plan: plan, status: fields[:status].to_s,
        actor: current_resource_owner, version: version, request_id: request.request_id
      )
      audit!(target: user, action: "subscription_assign", outcome: "assigned",
        changes: { plan: plan.code, status: subscription.status, version: subscription.lock_version })
    end
    render_json({ data: subscription_payload(subscription) })
  end

  def billing_events
    page, limit = pagination
    scope = Abroa::ServiceBillingEvent.order(occurred_at: :desc, id: :desc)
    if params[:user_id].present?
      raise ArgumentError, "Invalid user ID" unless valid_uuid?(params[:user_id])
      scope = scope.where(user_id: params[:user_id])
    end
    rows = scope.offset((page - 1) * limit).limit(limit + 1).to_a
    render_json({ data: rows.first(limit).map { |item| billing_payload(item) },
      meta: { page: page, limit: limit, next_page: rows.size > limit ? page + 1 : nil } })
  end

  def simulate_billing
    return unless ensure_write_access
    fields = body_fields!(:user_id, :service_subscription_id, :external_id,
      :kind, :occurred_at, :amount, :currency)
    raise ArgumentError, "Invalid user or subscription ID" unless
      valid_uuid?(fields[:user_id]) && valid_uuid?(fields[:service_subscription_id])
    raise ArgumentError, "Simulated callbacks must not contain a payment amount" if
      fields.key?(:amount) || fields.key?(:currency)

    occurred_at = Time.iso8601(fields.fetch(:occurred_at, "").to_s)
    raise ArgumentError, "Invalid event timestamp" if
      occurred_at < Time.utc(2020, 1, 1) || occurred_at > 7.days.from_now

    user = User.find(fields[:user_id])
    subscription = Abroa::ServiceSubscription.find(fields[:service_subscription_id])
    event = nil
    Abroa::ServiceBillingEvent.transaction do
      event = Abroa::ServiceBillingEvent.simulate!(
        user: user, subscription: subscription,
        external_id: fields[:external_id], kind: fields[:kind],
        occurred_at: occurred_at, amount: nil, currency: nil
      )
      audit!(target: user, action: "billing_simulated", outcome: "simulated",
        changes: { kind: event.kind, event_id_digest: Digest::SHA256.hexdigest(event.external_id)[0, 16] })
    end
    render_json({ data: billing_payload(event) })
  end

  private

    def subscription_payload(subscription)
      {
        id: subscription.id, user_id: subscription.user_id, plan: subscription.plan.code,
        status: subscription.status, started_at: subscription.started_at,
        ends_at: subscription.ends_at, version: subscription.lock_version
      }
    end

    def billing_payload(item)
      {
        id: item.id, user_id: item.user_id,
        service_subscription_id: item.service_subscription_id,
        kind: item.kind, status: item.status, occurred_at: item.occurred_at,
        amount: item.amount&.to_s("F"), currency: item.currency
      }
    end

    def audit!(target:, action:, outcome:, changes:)
      Abroa::PlatformAuditEvent.create!(
        actor_user_id: current_resource_owner.id, target_user_id: target.id,
        action: action, outcome: outcome, request_id: request.request_id,
        occurred_at: Time.current, safe_changes: changes.stringify_keys
      )
    end

    def require_commercial_read!
      require_commercial_permission!("operations.read")
    end

    def require_commercial_write!
      require_commercial_permission!("operations.write")
    end

    def require_commercial_permission!(permission)
      return if Abroa::PlatformRoleAssignment.permitted?(current_resource_owner, permission)

      render_json({ error: "forbidden", message: "Platform operations permission required" }, status: :forbidden)
    end

    def pagination
      [ bounded_positive(params[:page], 1, 1000), bounded_positive(params[:limit], 25, 100) ]
    end

    def bounded_positive(value, fallback, maximum)
      return fallback if value.nil?
      number = Integer(value.to_s, exception: false)
      raise ArgumentError, "Invalid page or limit" unless number && number.between?(1, maximum)
      number
    end

    def strict_version(value)
      raise ArgumentError, "Invalid optimistic version" unless value.is_a?(Integer) && value >= 0
      value
    end

    def date_window
      start_date = params[:from].present? ? Date.iso8601(params[:from].to_s) : 30.days.ago.utc.to_date
      end_date = params[:to].present? ? Date.iso8601(params[:to].to_s) : Date.current
      raise ArgumentError, "Invalid bounded date window" if start_date > end_date ||
        (end_date - start_date) > 366 || end_date > Date.current + 1
      [ start_date.beginning_of_day.utc, (end_date + 1).beginning_of_day.utc ]
    rescue Date::Error
      raise ArgumentError, "Invalid ISO date"
    end

    def commercial_validation(error)
      render_json({ error: "validation_failed", message: error.message }, status: :unprocessable_entity)
    end

    def commercial_conflict(_error)
      render_json({ error: "conflict", message: "Plan, event or subscription version changed" }, status: :conflict)
    end

    def commercial_forbidden(_error)
      render_json({ error: "forbidden", message: "Platform permission required" }, status: :forbidden)
    end
end
