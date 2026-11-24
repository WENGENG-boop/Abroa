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
      value = converted_goal_amount!(goal, account, entry.date, native_amount)
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
