module Abroa
  # Uses Sure Goal as the single backing ledger for a pool linked to a Goal.
  # The Abroa movement is an audit/provenance link, not another reservation.
  class GoalFundBridge
    def self.consume!(pool:, account:, entry:, native_amount:)
      goal = pool.goal
      raise ActiveRecord::RecordNotFound unless goal && goal.family_id == pool.family_id
      raise ArgumentError, "Goal source does not link this account" unless
        goal.goal_accounts.where(account_id: account.id).exists?
      raise ArgumentError, "A posted transaction is required" unless entry.transaction?
      value = converted_goal_amount!(goal, account, entry.date, native_amount)
      goal.consume!(value, account: account, transaction: entry.transaction)
    end

    def self.refund!(pool:, account:, entry:, native_amount:)
      goal = pool.goal
      raise ActiveRecord::RecordNotFound unless goal && goal.family_id == pool.family_id
      value = historical_refund_amount!(goal: goal, pool: pool,
        account: account, entry: entry, native_amount: native_amount)
      goal.with_lock do
        raise Goal::ConsumptionRefused.new(:not_active) unless goal.active? && !goal.maintained?
        link = goal.goal_accounts.lock.find_by!(account_id: account.id)
        # Goal#consume! turns whole-account backing into a fixed earmark.
        # A missing one cannot be safely increased from a refund.
        raise ArgumentError, "Original Goal earmark is no longer fixed" unless link.allocated_amount
        raise ArgumentError, "Refund exceeds remaining consumed Goal amount" if value > goal.consumed_amount.to_d

        # Restoring a previously consumed earmark is a new claim on cash that
        # must not compete with later goals and other Abroa pools.
        available = AllocationGuard.summary(account)[:unallocated_cash]
        raise ArgumentError, "Refunded cash is no longer unallocated" if native_amount > available
        link.update!(allocated_amount: link.allocated_amount + native_amount)
        goal.update!(consumed_amount: goal.consumed_amount.to_d - value)
      end
      goal.reload
    end

    # Restore the original goal-currency consumption, not a new gain/loss
    # computed from a refund-day rate. A refunded credit can cover several
    # original purchases with different historical rates.
    def self.historical_refund_amount!(goal:, pool:, account:, entry:, native_amount:)
      sources = RefundLink.active.where(family_id: pool.family_id, refund_entry_id: entry.id)
        .includes(:original_entry).limit(101).to_a
      raise ArgumentError, "Refund source count is invalid" if sources.empty? || sources.length > 100
      raise ArgumentError, "Refund provenance no longer reconciles" unless sources.all?(&:consistent?)

      consumed = pool.movements.where(account_id: account.id, kind: "consume",
        entry_key: sources.map(&:original_entry_id)).distinct.pluck(:entry_key)
      unless sources.all? { |source| consumed.include?(source.original_entry_id) }
        raise ArgumentError, "Refund contains a purchase not consumed by this Goal pool"
      end

      credited = sources.sum(BigDecimal("0")) { |source| source.refund_amount.to_d }
      raise ArgumentError, "Refund allocation has no positive credit" unless credited.positive?
      remaining = native_amount
      total_goal = BigDecimal("0")
      sources.each_with_index do |source, index|
        native_share = if index == sources.size - 1
          remaining
        else
          (native_amount * source.refund_amount.to_d / credited).round(4)
        end
        remaining -= native_share
        next unless native_share.positive?

        total_goal += converted_goal_amount!(goal, account, source.original_date, native_share)
      end
      raise ArgumentError, "Refund conversion cannot round to zero" unless total_goal.positive?
      total_goal
    end

    def self.converted_goal_amount!(goal, account, date, native_amount)
      money = goal.convert_money!(Money.new(native_amount, account.currency), date: date)
      amount = Decimal.money!(money.amount, positive: true)
      raise ArgumentError, "Goal conversion is below monetary precision" unless amount.positive?
      amount
    rescue Money::ConversionError
      raise ArgumentError, "Missing historical Sure Goal currency conversion"
    end
  end
end
