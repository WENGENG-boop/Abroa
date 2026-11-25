module Abroa
  # Links a posted Sure bank Entry to a personal claim, without minting cash.
  class DebtSettlement < ApplicationRecord
    self.table_name = "abroa_debt_settlements"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :actor, class_name: "User"
    belongs_to :personal_debt, class_name: "Abroa::PersonalDebt"
    belongs_to :entry
    belongs_to :rate_snapshot, class_name: "Abroa::RateSnapshot", optional: true
    belongs_to :refunded_settlement, class_name: "Abroa::DebtSettlement", optional: true
    belongs_to :refund_link, class_name: "Abroa::RefundLink", optional: true

    validates :native_amount, :applied_amount, :entry_amount, numericality: { greater_than: 0 }
    validates :kind, inclusion: { in: %w[payment refund source_refund] }
    validate :valid_scope

    def self.settle_for!(user, debt_id, entry_id:, amount:, key:)
      perform!(user, debt_id, entry_id: entry_id, amount: amount, key: key, kind: "payment")
    end

    def self.refund_for!(user, debt_id, entry_id:, amount:, refunded_settlement_id:, key:)
      perform!(user, debt_id, entry_id: entry_id, amount: amount, key: key,
        kind: "refund", refunded_settlement_id: refunded_settlement_id)
    end

    # A refund recorded by Sure against the *original purchase* also reduces
    # the other person's share of that purchase, without creating cash.
    def self.merchant_refund_for!(user, debt_id, refund_link_id:, key:)
      raise ArgumentError, "Invalid refund link" unless UuidFormat.valid?(refund_link_id)
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      digest = Digest::SHA256.hexdigest(key)
      request = Digest::SHA256.hexdigest([ debt_id, refund_link_id, "source_refund" ].join(":"))
      PersonalDebt.with_actor_for!(user, debt_id) do |debt|
        if (old = where(personal_debt_id: debt.id, creation_key_digest: digest).first)
          raise Conflict, "Idempotency key changed" unless old.creation_request_digest == request
          next old
        end
        raise Conflict, "Source refund requires an active consistent receivable" unless
          debt.status != "cancelled" && debt.kind == "paid_for_other" && debt.consistent?
        link = RefundLink.active.where(id: refund_link_id, family_id: debt.family_id,
          original_entry_id: debt.source_entry_id).lock.first!
        RefundLink.visible_to!(user, link.id)
        raise Conflict, "Original refund link changed" unless link.consistent?
        entry = EntryAllocation.locked_entry!(user, link.refund_entry_id)
        EntryAllocation.validate_entry!(entry)
        raise Conflict, "Refund bank entry already matched" if exists?(entry_id: entry.id)
        raise ArgumentError, "Purchase refund must be a posted inflow" unless
          entry.amount.negative? && entry.date == link.refund_date && entry.currency == link.refund_currency
        share = (link.applied_amount * debt.other_amount / debt.source_amount.abs).round(4)
        raise Conflict, "Purchase refund exceeds outstanding claim" if share.zero? ||
          share > debt.outstanding_amount
        settlement = create!(family: user.family, actor: user, personal_debt: debt,
          entry: entry, native_amount: link.refund_amount, native_currency: entry.currency,
          applied_amount: share, entry_amount: entry.amount.abs, entry_date: entry.date,
          kind: "source_refund", refund_link: link, rate_snapshot: link.rate_snapshot,
          creation_key_digest: digest, creation_request_digest: request)
        refresh_debt_after!(user, debt, settlement)
      end
    end

    def self.perform!(user, debt_id, entry_id:, amount:, key:, kind:, refunded_settlement_id: nil)
      raise ArgumentError, "Invalid settlement key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      raise ArgumentError, "Invalid bank entry ID" unless UuidFormat.valid?(entry_id)
      raise ArgumentError, "Unknown settlement kind" unless %w[payment refund].include?(kind)
      native = Decimal.money!(amount, positive: true)
      key_digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest([ debt_id, entry_id, native.to_s("F"),
        kind, refunded_settlement_id ].join(":"))
      PersonalDebt.with_actor_for!(user, debt_id) do |debt|
        previous = where(personal_debt_id: debt.id, creation_key_digest: key_digest).first
        if previous
          raise Conflict, "Idempotency key changed" unless previous.creation_request_digest == request_digest
          next previous
        end
        raise Conflict, "Cancelled or inconsistent personal debt" if debt.status == "cancelled" || !debt.consistent?
        raise Conflict, "Claim already settled" if kind == "payment" && debt.outstanding_amount.zero?
        entry = EntryAllocation.locked_entry!(user, entry_id)
        EntryAllocation.validate_entry!(entry)
        raise ArgumentError, "Bank entry has not posted" if entry.date > Date.current
        in_flow = entry.amount.negative?
        expected_inflow = (debt.direction == "receivable") == (kind == "payment")
        raise ArgumentError, "Settlement direction does not match claim" unless in_flow == expected_inflow
        raise ArgumentError, "Applied amount exceeds bank transaction" if native > entry.amount.abs
        raise Conflict, "Bank entry already matched to a debt" if exists?(entry_id: entry.id)
        refunded = nil
        if kind == "refund"
          refunded = debt.settlements.where(kind: "payment").find(refunded_settlement_id)
        end

        quote = RateSnapshot.quote(from: entry.currency, to: debt.currency, date: entry.date)
        raise Conflict, "Historical exchange rate missing" if quote.missing?
        applied = Decimal.money!(quote.convert(native).round(4), positive: true)
        if kind == "payment"
          raise Conflict, "Payment exceeds outstanding amount" if applied > debt.outstanding_amount
        else
          already_refunded = debt.settlements.where(kind: "refund", refunded_settlement_id: refunded.id).sum(:applied_amount)
          raise Conflict, "Refund exceeds original settlement" if applied > refunded.applied_amount - already_refunded
        end
        snapshot = entry.currency == debt.currency ? nil : quote.capture!(family: user.family)
        settlement = create!(family: user.family, actor: user, personal_debt: debt,
          entry: entry, native_amount: native, native_currency: entry.currency,
          applied_amount: applied, entry_amount: entry.amount.abs, entry_date: entry.date,
          kind: kind, refunded_settlement: refunded, rate_snapshot: snapshot,
          creation_key_digest: key_digest, creation_request_digest: request_digest)
        refresh_debt_after!(user, debt, settlement)
      end
    end

    def self.refresh_debt_after!(user, debt, settlement)
      settled = debt.net_settled_amount
      raise Conflict, "Personal claim exceeded by settlement" if settled.negative? || settled > debt.principal_amount
      new_status = settled.zero? ? "open" : (settled == debt.principal_amount ? "settled" : "partially_settled")
      debt.update!(status: new_status)
      debt.refresh_valuation!
      PlanningAuditEvent.record!(actor: user, event_type: "personal_debt.#{settlement.kind}",
        resource: settlement, safe_data: { personal_debt_id: debt.id,
          applied_amount: settlement.applied_amount.to_s("F"),
          currency: debt.currency, entry_id: settlement.entry_id })
      settlement
    end

    def consistent?
      return false unless personal_debt && entry && actor &&
        actor_id == personal_debt.owner_id && family_id == personal_debt.family_id &&
        entry.account.family_id == family_id && entry.currency == native_currency &&
        entry.date == entry_date && entry.amount.abs == entry_amount &&
        entry.transaction? && entry.transaction.kind == "standard" &&
        !entry.transaction.pending? && !entry.excluded? && !entry.split_parent? &&
        !entry.scheduled? && native_amount <= entry.amount.abs &&
        entry.date <= Date.current
      expected_inflow = (personal_debt.direction == "receivable") == (kind != "refund")
      return false unless entry.amount.negative? == expected_inflow
      reference_valid = case kind
      when "payment"
        refunded_settlement.nil? && refund_link.nil?
      when "refund"
        refund_link.nil? && refunded_settlement &&
          refunded_settlement.personal_debt_id == personal_debt_id &&
          refunded_settlement.kind == "payment"
      when "source_refund"
        refunded_settlement.nil? && refund_link &&
          personal_debt.kind == "paid_for_other" && refund_link.revoked_at.nil? &&
          refund_link.consistent? && refund_link.original_entry_id == personal_debt.source_entry_id &&
          refund_link.refund_entry_id == entry_id && refund_link.refund_amount == native_amount &&
          (refund_link.applied_amount * personal_debt.other_amount / personal_debt.source_amount.abs).round(4) ==
            applied_amount
      end
      return false unless reference_valid
      if kind == "source_refund"
        return rate_snapshot_id == refund_link.rate_snapshot_id &&
          entry.currency == refund_link.refund_currency
      end
      if native_currency == personal_debt.currency
        rate_snapshot.nil? && native_amount == applied_amount
      else
        rate_snapshot && rate_snapshot.family_id == family_id &&
          rate_snapshot.from_currency == native_currency &&
          rate_snapshot.to_currency == personal_debt.currency &&
          rate_snapshot.as_of == entry_date &&
          rate_snapshot.convert(native_amount).round(4) == applied_amount
      end
    rescue ArgumentError
      false
    end

    def payload
      { id: id, personal_debt_id: personal_debt_id, entry_id: entry_id, kind: kind,
        refunded_settlement_id: refunded_settlement_id, refund_link_id: refund_link_id,
        native_amount: native_amount.to_s("F"), native_currency: native_currency,
        applied_amount: applied_amount.to_s("F"), currency: personal_debt.currency,
        entry_date: entry_date.iso8601, consistent: consistent?, created_at: created_at.iso8601(6) }
    end

    private
      def valid_scope
        reference_valid = case kind
        when "payment" then refunded_settlement.nil? && refund_link.nil?
        when "refund" then refund_link.nil? && refunded_settlement &&
          refunded_settlement.personal_debt_id == personal_debt_id
        when "source_refund" then refunded_settlement.nil? && refund_link &&
          personal_debt && refund_link.original_entry_id == personal_debt.source_entry_id &&
          refund_link.refund_entry_id == entry_id
        end
        unless personal_debt && actor && entry && reference_valid &&
            actor_id == personal_debt.owner_id && family_id == personal_debt.family_id &&
            entry.account.family_id == family_id
          errors.add(:base, "Invalid debt settlement scope")
        end
      end
  end
end
