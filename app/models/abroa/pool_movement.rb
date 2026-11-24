module Abroa
  # Immutable virtual movement: this never changes the real Account balance
  # and never creates a Transaction or Entry.
  class PoolMovement < ApplicationRecord
    self.table_name = "abroa_pool_movements"
    KINDS = %w[allocate release reserve unreserve consume refund].freeze
    belongs_to :family
    belongs_to :actor, class_name: "User"
    belongs_to :pool, class_name: "Abroa::FundPool"
    belongs_to :account
    belongs_to :entry, optional: true
    belongs_to :rate_snapshot, class_name: "Abroa::RateSnapshot", optional: true
    belongs_to :reversal_of, class_name: "Abroa::PoolMovement", optional: true

    validates :kind, inclusion: { in: KINDS }
    validates :amount, numericality: { greater_than: 0 }
    validate :valid_provenance
    before_update { raise ActiveRecord::ReadOnlyError, "Pool movements are immutable" }

    def self.native_allocated_for(account)
      # Goal-linked pool movements are provenance only: Sure GoalAccount has
      # already changed its own earmark. Including those movements again
      # would subtract Goal consumption twice from usable account cash.
      joins(:pool).where(account_id: account.id, family_id: account.family_id,
        abroa_fund_pools: { goal_id: nil })
        .sum("CASE WHEN abroa_pool_movements.kind IN ('allocate','refund') THEN abroa_pool_movements.amount WHEN abroa_pool_movements.kind IN ('release','consume') THEN -abroa_pool_movements.amount ELSE 0 END").to_d
    end

    def self.apply_for!(user, pool_id, account_id:, kind:, amount:, entry_id: nil, fee_installment_id: nil, key:)
      value = Decimal.money!(amount, positive: true)
      raise ArgumentError, "Unknown pool movement" unless KINDS.include?(kind)
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      if fee_installment_id && !UuidFormat.valid?(fee_installment_id)
        raise ArgumentError, "Invalid fee reference"
      end
      if entry_id && !UuidFormat.valid?(entry_id)
        raise ArgumentError, "Invalid entry reference"
      end
      payload = {
        account_id: account_id, kind: kind, amount: value.to_s("F"),
        entry_id: entry_id, fee_installment_id: fee_installment_id
      }
      operation_key = Digest::SHA256.hexdigest([ user.id, pool_id, key ].join(":"))
      request_digest = Digest::SHA256.hexdigest(JSON.generate(payload))
      raise ActiveRecord::RecordNotFound unless user && user.active? && !user.guest?
      allowed = user.family.accounts.writable_by(user).find(account_id)
      raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, allowed).permits?(:write)
      # Sure Goal and Abroa must acquire this advisory lock BEFORE the family
      # row lock; otherwise Goal's FK on families can deadlock against our guard.
      ActiveRecord::Base.transaction do
        Goal.lock_whole_account_claims!(account_id)
        StudyProject.with_actor(user) do
          pool = FundPool.for_user(user).lock.find(pool_id)
          pool.project.ensure_writable!
          raise FundPool::Conflict, "Fund pool is archived" unless pool.status == "active"
          guarded = AllocationGuard.lock_account!(user, account_id)
          account = user.family.accounts.find(account_id)
          existing = where(family: user.family, operation_key: operation_key).first
          if existing
            raise FundPool::Conflict, "Idempotency key reused with different movement" unless
              existing.request_digest == request_digest && existing.pool_id == pool.id
            next existing
          end
          if pool.goal_id && %w[allocate release].include?(kind)
            raise ArgumentError, "Goal-linked pools are funded by Sure Goal; do not fund twice"
          end
          raise ArgumentError, "Missing or invalid source account currency" unless account.currency == guarded[:currency]
          entry, snapshot = prepare_entry!(user, account, kind: kind, entry_id: entry_id)
          allocated = pool.native_allocated_for(account)
          reserved = pool.native_reserved_for(account)
          reserved_released = BigDecimal("0")

          case kind
          when "allocate"
            raise ArgumentError, "Cash is fully committed or in shortfall" if guarded[:unallocated_cash] < value
          when "release"
            raise ArgumentError, "Cannot release funds reserved for an obligation" if value > allocated - reserved
          when "reserve"
            raise ArgumentError, "Reservation requires an obligation identifier" unless fee_installment_id
            raise ArgumentError, "Insufficient free funds in pool" if value > allocated - reserved
          when "unreserve"
            raise ArgumentError, "Unreserve requires an obligation identifier" unless fee_installment_id
            raise ArgumentError, "Reservation already consumed or released" if value > reserved_for_fee(pool, account, fee_installment_id)
          when "consume"
            raise ArgumentError, "Expense is not available for this pool" if value > allocated
            released = fee_installment_id ? reserved_for_fee(pool, account, fee_installment_id) : BigDecimal("0")
            reserved_released = [ value, released ].min
            raise ArgumentError, "Expense would consume another obligation's funds" if value - reserved_released > allocated - reserved
            raise ArgumentError, "Expense already allocated to other pools" if
              where(kind: "consume", entry_key: entry.id).sum(:amount) + value > entry_native_amount!(entry, account)
            GoalFundBridge.consume!(pool: pool, account: account, entry: entry, native_amount: value) if pool.goal_id
          when "refund"
            verify_linked_refund!(user, pool, account, entry, value)
            GoalFundBridge.refund!(pool: pool, account: account, entry: entry, native_amount: value) if pool.goal_id
          end

          record = create!(family: user.family, actor: user, pool: pool, account: account,
            entry: entry, entry_key: entry&.id, fee_installment_id: fee_installment_id,
            rate_snapshot: snapshot, kind: kind, amount: value, currency: account.currency,
            reserved_released_amount: reserved_released, operation_key: operation_key, request_digest: request_digest)
          PlanningAuditEvent.record!(actor: user, event_type: "fund_pool.#{kind}", resource: record,
            safe_data: { pool_id: pool.id, account_id: account.id, currency: account.currency,
              amount: value.to_s("F"), entry_id: entry&.id, fee_installment_id: fee_installment_id })
          record
        end
      end
    end

    def self.reserved_for_fee(pool, account, fee_id)
      pool.movements.where(account_id: account.id, fee_installment_id: fee_id)
        .sum("CASE WHEN kind = 'reserve' THEN amount WHEN kind = 'unreserve' THEN -amount WHEN kind = 'consume' THEN -reserved_released_amount ELSE 0 END").to_d
    end

    def self.prepare_entry!(user, account, kind:, entry_id:)
      return [ nil, nil ] unless %w[consume refund].include?(kind)
      raise ArgumentError, "An actual ledger entry is required" unless entry_id
      entry = account.entries.lock.find(entry_id)
      unless entry.transaction? && entry.transaction.kind == "standard" &&
          !entry.transaction.pending? && !entry.excluded? && !entry.split_parent? &&
          !entry.scheduled? && !entry.amount.zero? && entry.date <= Date.current
        raise ArgumentError, "Only posted ordinary transactions may be consumed or refunded"
      end
      if (kind == "consume" && !entry.amount.positive?) || (kind == "refund" && !entry.amount.negative?)
        raise ArgumentError, "Ledger entry has the wrong direction"
      end
      if entry.currency == account.currency
        [ entry, nil ]
      else
        quote = RateSnapshot.quote(from: entry.currency, to: account.currency, date: entry.date)
        raise ArgumentError, "Missing historical movement rate" if quote.missing?
        [ entry, quote.capture!(family: user.family) ]
      end
    end

    def self.entry_native_amount!(entry, account)
      return entry.amount.abs if entry.currency == account.currency
      quote = RateSnapshot.quote(from: entry.currency, to: account.currency, date: entry.date)
      raise ArgumentError, "Missing historical movement rate" if quote.missing?
      quote.convert(entry.amount.abs).round(4)
    end

    def self.verify_linked_refund!(user, pool, account, entry, value)
      links = RefundLink.active.where(family_id: user.family_id, refund_entry_id: entry.id)
      raise ArgumentError, "Refund lacks a confirmed original purchase" unless links.exists?
      raise ArgumentError, "Refund association is inconsistent" unless links.all?(&:consistent?)
      source_ids = links.map(&:original_entry_id)
      consumed = pool.movements.where(account_id: account.id, kind: "consume", entry_key: source_ids).sum(:amount)
      prior = pool.movements.where(account_id: account.id, kind: "refund", entry_key: links.map(&:refund_entry_id)).sum(:amount)
      raise ArgumentError, "Refund exceeds this pool's consumed purchases" if consumed < prior + value
      # A credit can only restore its real received amount once, across pools.
      already_restored = where(family_id: user.family_id, kind: "refund", entry_key: entry.id).sum(:amount)
      max_refundable = entry_native_amount!(entry, account)
      raise ArgumentError, "Refund exceeds real credited amount" if already_restored + value > max_refundable
      # For partial linked refunds, the link is the authoritative cap.
      linked_total = links.sum { |link| link.refund_amount }
      raise ArgumentError, "Refund exceeds matched refund amount" if entry.currency == account.currency &&
        already_restored + value > linked_total
    end

    def payload
      { id: id, pool_id: pool_id, account_id: account_id, kind: kind,
        amount: amount.to_s("F"), currency: currency, entry_id: entry_id,
        fee_installment_id: fee_installment_id,
        reserved_released_amount: reserved_released_amount.to_s("F"), created_at: created_at.iso8601(6) }
    end

    private
      def valid_provenance
        unless pool && account && actor && family_id == pool.family_id &&
            family_id == account.family_id && family_id == actor.family_id && currency == account.currency &&
            (entry.nil? || (entry.account_id == account_id && entry.id == entry_key))
          errors.add(:base, "Movement provenance does not match original financial facts")
        end
      end
  end
end
