module Abroa
  # A reversal only links a real posted outgoing transfer to the original matched
  # receipt. It never creates a negative synthetic receipt or changes ledger cash.
  class FundingReversal < ApplicationRecord
    self.table_name = "abroa_funding_reversals"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :funding_receipt, class_name: "Abroa::FundingReceipt"
    belongs_to :actor, class_name: "User"
    belongs_to :entry
    belongs_to :rate_snapshot, class_name: "Abroa::RateSnapshot", optional: true

    validates :native_amount, :applied_amount, :entry_amount, numericality: { greater_than: 0 }
    validates :entry_currency, presence: true
    validate :valid_ledger_provenance

    def self.reverse_for!(student, receipt_id, entry_id:, key:)
      raise ArgumentError, "Invalid reversal key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      raise ArgumentError, "Invalid reversal entry" unless UuidFormat.valid?(entry_id)
      key_digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest([ receipt_id, entry_id ].join(":"))
      StudyProject.with_actor(student) do
        receipt = FundingReceipt.for_student(student).find(receipt_id)
        plan = FundingPlan.for_student(student).lock.find(receipt.funding_plan_id)
        receipt.lock!
        old = where(funding_receipt_id: receipt.id, creation_key_digest: key_digest).first
        if old
          raise Conflict, "Reversal request changed" unless old.creation_request_digest == request_digest
          next old
        end
        raise Conflict, "Funding receipt provenance changed" unless receipt.consistent?
        entry = EntryAllocation.locked_entry!(student, entry_id)
        EntryAllocation.validate_entry!(entry)
        raise ArgumentError, "Refund must be posted outgoing transfer" unless
          entry.amount.positive? && entry.date <= Date.current
        raise ActiveRecord::RecordNotFound unless entry.account_id == receipt.entry.account_id
        raise Conflict, "Refund entry already used" if exists?(entry_id: entry.id)
        raise Conflict, "Refund entry is the same as original" if entry.id == receipt.entry_id
        quote = RateSnapshot.quote(from: entry.currency, to: receipt.native_currency, date: entry.date)
        raise Conflict, "Historical refund rate missing" if quote.missing?
        returned_native = Decimal.money!(quote.convert(entry.amount.abs).round(4), positive: true)
        already = receipt.reversals.sum(:native_amount)
        raise Conflict, "Refund exceeds previously received amount" if returned_native > receipt.native_amount - already
        applied = if returned_native == receipt.native_amount - already
          # Final partial reversal reclaims the remaining original quote exactly.
          receipt.applied_amount - receipt.reversals.sum(:applied_amount)
        else
          Decimal.money!((receipt.applied_amount * returned_native / receipt.native_amount).round(4),
            positive: true)
        end
        snapshot = quote.from_currency == quote.to_currency ? nil : quote.capture!(family: student.family)
        record = create!(family: student.family, funding_receipt: receipt, actor: student,
          entry: entry, rate_snapshot: snapshot, native_amount: returned_native,
          native_currency: receipt.native_currency, entry_amount: entry.amount.abs,
          entry_currency: entry.currency, applied_amount: applied, entry_date: entry.date,
          creation_key_digest: key_digest, creation_request_digest: request_digest)
        PlanningAuditEvent.record!(actor: student, event_type: "funding_receipt.reversed", resource: record,
          safe_data: { funding_plan_id: plan.id, amount: applied.to_s("F"), currency: plan.currency })
        plan.refresh_after_receipt!
        record
      end
    end

    def consistent?
      return false unless funding_receipt && funding_receipt.consistent? && entry &&
        entry.account.family_id == family_id && actor_id == funding_receipt.funding_plan.student_user_id &&
        entry.account_id == funding_receipt.entry.account_id &&
        entry.date == entry_date && entry.amount.positive? &&
        entry.amount.abs == entry_amount && entry.currency == entry_currency &&
        entry.transaction? && entry.transaction.kind == "standard" &&
        !entry.transaction.pending? && !entry.excluded? && !entry.split_parent? && !entry.scheduled?

      if entry_currency == native_currency
        rate_snapshot.nil? && native_amount == entry_amount
      else
        rate_snapshot && rate_snapshot.family_id == family_id &&
          rate_snapshot.from_currency == entry_currency &&
          rate_snapshot.to_currency == native_currency &&
          (entry_amount * rate_snapshot.rate).round(4) == native_amount
      end
    rescue ArgumentError
      false
    end

    def payload_for(student)
      raise ActiveRecord::RecordNotFound unless student&.active? && student.id == actor_id &&
        student.family_id == family_id
      { id: id, funding_receipt_id: funding_receipt_id, entry_id: entry_id,
        native_amount: native_amount.to_s("F"), native_currency: native_currency,
        applied_amount: applied_amount.to_s("F"), entry_date: entry_date.iso8601,
        consistent: consistent? }
    end

    private
      def valid_ledger_provenance
        unless funding_receipt && entry && actor &&
            family_id == funding_receipt.family_id && actor_id == funding_receipt.funding_plan.student_user_id &&
            entry.account.family_id == family_id && entry.account_id == funding_receipt.entry.account_id &&
            entry.amount.positive? && entry.date == entry_date &&
            entry.amount.abs == entry_amount && entry.currency == entry_currency &&
            native_currency == funding_receipt.native_currency &&
            (!rate_snapshot || rate_snapshot.family_id == family_id)
          errors.add(:base, "Invalid funding reversal provenance")
        end
      end
  end
end
