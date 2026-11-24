module Abroa
  # A fee settlement refers to an existing, confirmed ledger fact. The only
  # amount written here is a virtual share; no Entry, Transaction or balance
  # is created or modified.
  class FeeSettlement < ApplicationRecord
    self.table_name = "abroa_fee_settlements"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :actor, class_name: "User"
    belongs_to :fee_installment, class_name: "Abroa::FeeInstallment"
    belongs_to :allocation, class_name: "Abroa::EntryAllocation", optional: true
    belongs_to :refund_link, class_name: "Abroa::RefundLink", optional: true
    belongs_to :rate_snapshot, class_name: "Abroa::RateSnapshot", optional: true

    scope :visible_to, ->(user) do
      permitted_accounts = user.family.accounts.accessible_by(user).select(:id)
      permitted_entries = Entry.where(account_id: permitted_accounts).select(:id)
      permitted_allocations = EntryAllocation.visible_to(user).select(:id)
      permitted_refunds = RefundLink.where(family_id: user.family_id,
        original_entry_id: permitted_entries, refund_entry_id: permitted_entries).select(:id)
      where(family_id: user.family_id, kind: "payment", allocation_id: permitted_allocations)
        .or(where(family_id: user.family_id, kind: "refund", refund_link_id: permitted_refunds))
    end

    validates :kind, inclusion: { in: %w[payment refund] }
    validates :amount, :fee_amount, numericality: { greater_than: 0 }
    validate :valid_provenance, on: :create

    def self.pay_for!(user, installment_id, allocation_id:, amount:, key:)
      perform!(user, installment_id, source_id: allocation_id, amount: amount, kind: "payment", key: key)
    end

    def self.refund_for!(user, installment_id, refund_link_id:, amount:, key:)
      perform!(user, installment_id, source_id: refund_link_id, amount: amount, kind: "refund", key: key)
    end

    def self.perform!(user, installment_id, source_id:, amount:, kind:, key:)
      value = Decimal.money!(amount, positive: true)
      unless key.is_a?(String) && key.present? && key.bytesize <= 128
        raise ArgumentError, "Idempotency-Key must contain 1 to 128 bytes"
      end
      raise ArgumentError, "Invalid settlement source" unless UuidFormat.valid?(source_id)
      raise ArgumentError, "Unknown fee settlement type" unless %w[payment refund].include?(kind)
      digest = Digest::SHA256.hexdigest([ user.id, installment_id, key ].join(":"))
      request = Digest::SHA256.hexdigest(JSON.generate({ source_id: source_id, amount: value.to_s("F"), kind: kind }))
      initial_plan = FeeInstallment.for_user(user).find(installment_id).fee_plan
      pool_id = initial_plan.fund_pool_id
      if pool_id
        ActiveRecord::Base.transaction do
          movement = movement_source_for!(user, initial_plan, source_id: source_id, value: value, kind: kind)
          # Acquiring the Goal advisory lock before the family row lock
          # preserves the ordering enforced by Sure GoalAccount writers.
          Goal.lock_whole_account_claims!(movement[:account_id])
          PoolMovement.apply_for!(user, pool_id, account_id: movement[:account_id],
            kind: kind == "payment" ? "consume" : "refund",
            amount: movement[:amount], entry_id: movement[:entry_id],
            fee_installment_id: installment_id, key: "fee-settlement:#{key}")
          perform_core!(user, installment_id, source_id: source_id, value: value,
            kind: kind, digest: digest, request: request, expected_pool_id: pool_id)
        end
      else
        perform_core!(user, installment_id, source_id: source_id, value: value,
          kind: kind, digest: digest, request: request, expected_pool_id: nil)
      end
    end

    def self.movement_source_for!(user, plan, source_id:, value:, kind:)
      if kind == "payment"
        allocation = EntryAllocation.visible_to(user).where(project_id: plan.project_id).find(source_id)
        entry = allocation.entry
        from_currency = entry.currency
        date = entry.date
      else
        link = RefundLink.visible_to!(user, source_id)
        entry = link.refund_entry
        from_currency = link.currency
        date = link.refund_date
      end
      account = user.family.accounts.writable_by(user).find(entry.account_id)
      raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)
      quote = RateSnapshot.quote(from: from_currency, to: account.currency, date: date)
      raise ArgumentError, "Missing historical pool movement exchange rate" if quote.missing?
      native = quote.convert(value).round(4)
      raise ArgumentError, "Movement below native currency precision" unless native.positive?
      { account_id: account.id, entry_id: entry.id, amount: native.to_s("F") }
    end

    def self.perform_core!(user, installment_id, source_id:, value:, kind:, digest:, request:, expected_pool_id:)
      StudyProject.with_actor(user) do
        installment = FeeInstallment.for_user(user).lock.find(installment_id)
        plan = installment.fee_plan
        raise FeePlan::Conflict, "Fee pool changed during settlement" unless plan.fund_pool_id == expected_pool_id
        plan.project.ensure_writable!
        raise FeePlan::Conflict, "Fee cannot be settled" if plan.status != "active" || installment.state != "confirmed"
        if (existing = where(family: user.family, operation_key: digest).first)
          raise Conflict, "Settlement idempotency key changed" unless existing.request_digest == request &&
            existing.fee_installment_id == installment.id
          next existing
        end

        if kind == "payment"
          allocation = EntryAllocation.visible_to(user).where(project_id: plan.project_id).find(source_id)
          entry = EntryAllocation.locked_entry!(user, allocation.entry_id)
          raise ArgumentError, "Allocation is no longer reconciled" unless allocation.consistent? &&
            entry.amount.positive? && entry.date <= Date.current && entry.currency == allocation.currency
          used = where(allocation_id: allocation.id, kind: "payment").sum(:amount)
          raise ArgumentError, "Payment exceeds its allocated ledger amount" if used + value > allocation.amount
          source_date = entry.date
          currency = entry.currency
          refund_link = nil
        else
          refund_link = RefundLink.active.where(family: user.family).find(source_id)
          original = EntryAllocation.locked_entry!(user, refund_link.original_entry_id)
          EntryAllocation.locked_entry!(user, refund_link.refund_entry_id)
          raise ArgumentError, "Refund no longer reconciles with ledger" unless refund_link.consistent?
          # Only a refund of a payment made towards THIS installment can
          # reduce that installment's remaining liability.
          paid_original = installment.settlements.where(kind: "payment")
            .joins(:allocation).where(abroa_entry_allocations: { entry_id: original.id }).sum(:amount)
          already_used = where(refund_link_id: refund_link.id, kind: "refund").sum(:amount)
          refunded_original = installment.settlements.where(kind: "refund")
            .joins(:refund_link).where(abroa_refund_links: { original_entry_id: original.id }).sum(:amount)
          if paid_original <= refunded_original || value > paid_original - refunded_original ||
              already_used + value > refund_link.applied_amount
            raise ArgumentError, "Refund exceeds linked fee payment or authoritative refund"
          end
          allocation = nil
          source_date = refund_link.refund_date
          currency = refund_link.currency
        end

        quote = RateSnapshot.quote(from: currency, to: plan.currency, date: source_date)
        raise ArgumentError, "Missing historical fee exchange rate" if quote.missing?
        converted = quote.convert(value).round(4)
        raise ArgumentError, "Converted payment cannot round to zero" unless converted.positive?
        available = kind == "payment" ? installment.outstanding_amount : installment.paid_amount
        raise ArgumentError, "Settlement exceeds remaining fee amount" if converted > available
        snapshot = currency == plan.currency ? nil : quote.capture!(family: user.family)
        record = create!(family: user.family, actor: user, fee_installment: installment,
          allocation: allocation, refund_link: refund_link,
          kind: kind, amount: value, currency: currency, fee_amount: converted,
          fee_currency: plan.currency, source_date: source_date,
          rate_snapshot: snapshot, operation_key: digest, request_digest: request)
        PlanningAuditEvent.record!(actor: user, event_type: "fee_settlement.#{kind}", resource: record,
          safe_data: { installment_id: installment.id, amount: value.to_s("F"),
            currency: currency, fee_amount: converted.to_s("F"), source_id: source_id })
        record
      end
    end

    def consistent?
      return false unless fee_installment && fee_installment.family_id == family_id &&
        fee_installment.fee_plan.currency == fee_currency
      source = if kind == "payment"
        return false unless allocation && allocation.consistent? && allocation.project_id == fee_installment.fee_plan.project_id
        allocation.entry
      else
        return false unless refund_link && refund_link.revoked_at.nil? && refund_link.consistent?
        refund_link
      end
      expected_date = kind == "payment" ? source.date : source.refund_date
      expected_currency = kind == "payment" ? source.currency : source.currency
      return false unless expected_date == source_date && expected_currency == currency
      if currency == fee_currency
        rate_snapshot.nil? && fee_amount == amount
      else
        rate_snapshot && rate_snapshot.family_id == family_id &&
          rate_snapshot.from_currency == currency && rate_snapshot.to_currency == fee_currency &&
          rate_snapshot.as_of == source_date && rate_snapshot.convert(amount).round(4) == fee_amount
      end
    rescue ArgumentError
      false
    end

    def readonly?
      persisted? || super
    end

    def payload
      { id: id, fee_installment_id: fee_installment_id, kind: kind,
        allocation_id: allocation_id, refund_link_id: refund_link_id,
        amount: amount.to_s("F"), currency: currency, fee_amount: fee_amount.to_s("F"),
        fee_currency: fee_currency, source_date: source_date.iso8601,
        rate_snapshot_id: rate_snapshot_id, consistent: consistent?, created_at: created_at.iso8601(6) }
    end

    private
      def valid_provenance
        unless fee_installment && actor && fee_installment.family_id == family_id && actor.family_id == family_id &&
            fee_installment.fee_plan.currency == fee_currency &&
            ((kind == "payment" && allocation && !refund_link) || (kind == "refund" && refund_link && !allocation))
          errors.add(:base, "Invalid fee payment provenance")
        end
      end
  end
end
