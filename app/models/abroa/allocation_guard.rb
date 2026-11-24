module Abroa
  # AllocationGuard shares the account's original-currency cash with Sure Goal
  # earmarks. Neither a pool allocation nor an earmark is a new ledger entry.
  class AllocationGuard
    ZERO = BigDecimal("0")
    CASH_TYPES = %w[Depository].freeze

    def self.summary_for!(user, account_id)
      raise ActiveRecord::RecordNotFound unless user&.active?
      account = user.family.accounts.accessible_by(user).find(account_id)
      summary(account)
    end

    def self.summary(account)
      raise ArgumentError, "Account is not a cash depository" unless CASH_TYPES.include?(account.accountable_type)
      raise ArgumentError, "Account cannot fund a pool" unless account.status == "active" && account.balance
      cash = [ ZERO, Decimal.money!(account.balance) ].max
      goal_rows = GoalAccount.joins(:goal)
        .where(account_id: account.id, goals: { family_id: account.family_id })
        .where.not(goals: { state: Goal::RELEASED_STATES })
        .pluck(:allocated_amount)
      # nil is Sure's whole-account reservation. Legacy multiple whole links
      # must expose their overclaim rather than silently deduplicating them.
      goal_reserved = goal_rows.sum { |amount| amount.nil? ? cash : amount }.to_d
      pool_reserved = PoolMovement.native_allocated_for(account).to_d
      total = goal_reserved + pool_reserved
      {
        account_id: account.id, currency: account.currency, usable_cash: cash,
        goal_reserved: goal_reserved, pool_reserved: pool_reserved,
        reserved_total: total, unallocated_cash: [ ZERO, cash - total ].max,
        shortfall: [ ZERO, total - cash ].max
      }
    end

    # The advisory lock is shared with Sure's GoalAccount write path.
    # Both sides must acquire it before checking any available funds.
    def self.lock_account!(user, account_id)
      account = user.family.accounts.writable_by(user).find(account_id)
      raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)
      Goal.lock_whole_account_claims!(account.id)
      account.lock!
      summary(account)
    end
  end
end
