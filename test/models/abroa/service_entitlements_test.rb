require "test_helper"

class Abroa::ServiceEntitlementsTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @other = users(:empty)
    @platform_admin = users(:sure_support_staff)
    Abroa::PlatformRoleAssignment.create!(user: @platform_admin, role: "system_admin")
    @plan = Abroa::ServicePlan.create!(
      code: "managed-ai-small", name: "Test managed AI",
      entitlements: { "ai_calls" => { "limit" => 2 }, "bank_syncs" => { "limit" => 1 } }
    )
  end

  test "unpriced plan never invents zero cost, payment currency or charge" do
    assert_nil @plan.price_amount
    assert_nil @plan.price_currency
    assert_nil @plan.entitlement_for("core_finance")
    assert_equal 2, @plan.entitlement_for("ai_calls").fetch("limit")
  end

  test "core finance remains free without subscription even on managed cloud" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    assert Abroa::ServiceEntitlements.permitted?(@user, "core_finance")
    assert Abroa::ServiceEntitlements.permitted?(@user, "study_projects")
    assert Abroa::ServiceEntitlements.permitted?(@user, "family_collaboration")
    assert_nil Abroa::ServiceEntitlements.summary_for(@user).dig(:subscription, :plan)
  end

  test "self hosted core remains enabled and never requires an official plan" do
    Rails.application.config.stubs(:app_mode).returns("self_hosted".inquiry)
    assert Abroa::ServiceEntitlements.permitted?(@user, "core_finance")
    assert Abroa::ServiceEntitlements.permitted?(@user, "bank_syncs")
    assert_nil Abroa::ServiceEntitlements.summary_for(@user).dig(:subscription, :plan)
    assert_equal 0, Abroa::ServiceSubscription.count
  end

  test "idempotent usage, quota and cross tenant separation" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Abroa::ServiceSubscription.assign!(user: @user, plan: @plan, status: "active", actor: @platform_admin)
    first = Abroa::ServiceEntitlements.consume!(
      user: @user, feature: "ai_calls", source: "abroa_ai", event_id: "call-1", quantity: 1
    )
    second = Abroa::ServiceEntitlements.consume!(
      user: @user, feature: "ai_calls", source: "abroa_ai", event_id: "call-1", quantity: 1
    )
    assert_equal first.id, second.id
    assert_equal 1, Abroa::ServiceUsageEvent.where(user: @user).count
    assert_equal 1, Abroa::ServiceEntitlements.summary_for(@user).dig(:quotas, "ai_calls", :remaining)
    Abroa::ServiceEntitlements.consume!(
      user: @user, feature: "ai_calls", source: "abroa_ai", event_id: "call-2", quantity: 1
    )
    assert_raises(Abroa::ServiceEntitlements::LimitExceeded) do
      Abroa::ServiceEntitlements.consume!(
        user: @user, feature: "ai_calls", source: "abroa_ai", event_id: "call-3", quantity: 1
      )
    end
    assert_equal 2, Abroa::ServiceUsageEvent.where(user: @user).count
    assert_equal 0, Abroa::ServiceUsageEvent.where(user: @other).count
    assert_nil Abroa::ServiceEntitlements.summary_for(@other).dig(:subscription, :plan)
  end

  test "monthly usage is accounted in different immutable UTC periods" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Abroa::ServiceSubscription.assign!(user: @user, plan: @plan, status: "active", actor: @platform_admin)
    travel_to Time.utc(2026, 10, 31, 23, 30) do
      Abroa::ServiceEntitlements.consume!(
        user: @user, feature: "bank_syncs", source: "provider", event_id: "sync-oct", quantity: 1
      )
      assert_equal 0, Abroa::ServiceEntitlements.summary_for(@user).dig(:quotas, "bank_syncs", :remaining)
    end
    travel_to Time.utc(2026, 11, 1, 0, 30) do
      assert_equal 1, Abroa::ServiceEntitlements.summary_for(@user).dig(:quotas, "bank_syncs", :remaining)
      Abroa::ServiceEntitlements.consume!(
        user: @user, feature: "bank_syncs", source: "provider", event_id: "sync-nov", quantity: 1
      )
    end
    assert_equal 2, Abroa::ServiceUsageEvent.where(user: @user).count
  end

  test "different event source cannot spoof duplicate billing and unknown cost stays null" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Abroa::ServiceSubscription.assign!(user: @user, plan: @plan, status: "active", actor: @platform_admin)
    first = Abroa::ServiceEntitlements.consume!(
      user: @user, feature: "ai_calls", source: "abroa_ai", event_id: "shared-id", quantity: 1
    )
    second = Abroa::ServiceEntitlements.consume!(
      user: @user, feature: "ai_calls", source: "sure_ai", event_id: "shared-id", quantity: 1
    )
    assert_equal first.id, second.id
    assert_nil first.cost_amount
    assert_nil first.cost_currency
    assert_nil second.cost_amount
    assert_equal 1, Abroa::ServiceUsageEvent.where(user: @user).count
  end

  test "real PostgreSQL concurrent quota reservations cannot overspend and retries do not debit twice" do
    Rails.application.config.stubs(:app_mode).returns("managed".inquiry)
    Abroa::ServiceSubscription.assign!(user: @user, plan: @plan,
      status: "active", actor: @platform_admin)
    results = Queue.new
    threads = 4.times.map do |index|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          begin
            event = Abroa::ServiceEntitlements.consume!(
              user: User.find(@user.id), feature: "ai_calls",
              source: "abroa_ai", event_id: "parallel-#{index}", quantity: 1
            )
            results << [ "success", event.id ]
          rescue Abroa::ServiceEntitlements::LimitExceeded
            results << [ "limit", nil ]
          end
        end
      end
    end
    threads.each(&:join)
    outcomes = 4.times.map { results.pop }
    assert_equal 2, outcomes.count { |status, _id| status == "success" }
    assert_equal 2, outcomes.count { |status, _id| status == "limit" }
    assert_equal 2, Abroa::ServiceUsageEvent.where(user: @user, feature: "ai_calls").count
    assert_equal 2, Abroa::ServiceQuotaCounter.where(user: @user,
      feature: "ai_calls").first.used_count
  end

  test "simulated out of order payment and refund events are idempotent and never post to ledger" do
    subscription = Abroa::ServiceSubscription.assign!(
      user: @user, plan: @plan, status: "active", actor: @platform_admin
    )
    entries = Entry.count
    Abroa::ServiceBillingEvent.simulate!(
      user: @user, subscription: subscription, external_id: "evt-2026-refund",
      kind: "refund", occurred_at: Time.utc(2026, 11, 27),
      amount: nil, currency: nil
    )
    Abroa::ServiceBillingEvent.simulate!(
      user: @user, subscription: subscription, external_id: "evt-2026-old",
      kind: "payment", occurred_at: Time.utc(2026, 11, 25),
      amount: nil, currency: nil
    )
    Abroa::ServiceBillingEvent.simulate!(
      user: @user, subscription: subscription, external_id: "evt-2026-refund",
      kind: "refund", occurred_at: Time.utc(2026, 11, 27),
      amount: nil, currency: nil
    )
    assert_equal 2, Abroa::ServiceBillingEvent.count
    assert_equal entries, Entry.count
    assert_nil Abroa::ServiceBillingEvent.first.amount
    assert_equal "active", subscription.reload.status
  end
end
