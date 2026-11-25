module Abroa
  # Verified receipt = a projection of an already-posted student-family ledger Entry.
  # Never creates, imports, edits or deletes money and never changes Account.balance.
  class FundingReceipt < ApplicationRecord
    self.table_name = "abroa_funding_receipts"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :funding_plan, class_name: "Abroa::FundingPlan"
    belongs_to :actor, class_name: "User"
    belongs_to :entry
    belongs_to :rate_snapshot, class_name: "Abroa::RateSnapshot", optional: true
    has_many :reversals, class_name: "Abroa::FundingReversal", dependent: :restrict_with_exception
    validates :native_amount, :applied_amount, numericality: { greater_than: 0 }
    validate :valid_ledger_provenance

    def self.for_student(student)
      raise ActiveRecord::RecordNotFound unless student&.active?
      joins(:funding_plan).where(family_id: student.family_id,
        abroa_funding_plans: { student_user_id: student.id })
    end

    def self.match_for!(student, plan_id, entry_id:, key:, due_on: nil)
      raise ArgumentError, "Invalid match key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      raise ArgumentError, "Invalid entry ID" unless UuidFormat.valid?(entry_id)
      if due_on && !due_on.is_a?(Date)
        due_on = Date.iso8601(due_on.to_s)
      end
      key_digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest([ plan_id, entry_id, due_on&.iso8601 ].join(":"))
      StudyProject.with_actor(student) do
        plan = FundingPlan.for_student(student).lock.find(plan_id)
        existing = where(funding_plan_id: plan.id, creation_key_digest: key_digest).first
        if existing
          raise Conflict, "Match idempotency key changed" unless existing.creation_request_digest == request_digest
          next existing
        end
        raise Conflict, "Funding plan not matchable" unless
          %w[confirmed partially_received].include?(plan.status)
        raise Conflict, "Funding project archived" if plan.project.status == "archived"
        raise ActiveRecord::RecordNotFound unless plan.destination_account_id.present?
        entry = EntryAllocation.locked_entry!(student, entry_id)
        EntryAllocation.validate_entry!(entry)
        raise ArgumentError, "Funding receipt must be posted inflow" unless entry.amount.negative? &&
          entry.date <= Date.current
        raise ActiveRecord::RecordNotFound unless entry.account_id == plan.destination_account_id
        raise Conflict, "Ledger entry already claimed by funding match" if exists?(entry_id: entry.id)
        due_on ||= plan.frequency == "once" ? plan.scheduled_on : nil
        raise ArgumentError, "Due date must match an expected installment" unless
          due_on && plan.schedule_dates.include?(due_on)
        native = Decimal.money!(entry.amount.abs, positive: true)
        quote = RateSnapshot.quote(from: entry.currency, to: plan.currency, date: entry.date)
        raise Conflict, "Historical exchange rate missing" if quote.missing?
        applied = Decimal.money!(quote.convert(native).round(4), positive: true)
        raise Conflict, "Receipt exceeds remaining planned funding" if applied > plan.outstanding_total
        snapshot = quote.from_currency == quote.to_currency ? nil : quote.capture!(family: student.family)
        record = create!(family: student.family, funding_plan: plan, actor: student, entry: entry,
          native_amount: native, native_currency: entry.currency, applied_amount: applied,
          rate_snapshot: snapshot, entry_date: entry.date, due_on: due_on,
          creation_key_digest: key_digest, creation_request_digest: request_digest)
        PlanningAuditEvent.record!(actor: student, event_type: "funding_receipt.matched", resource: record,
          safe_data: { funding_plan_id: plan.id, native_amount: native.to_s("F"),
            currency: entry.currency, applied_amount: applied.to_s("F") })
        plan.refresh_after_receipt!
        record
      end
    end

    def consistent?
      entry && entry.account.family_id == family_id && funding_plan.family_id == family_id &&
        actor_id == funding_plan.student_user_id && entry.account_id == funding_plan.destination_account_id &&
        entry.currency == native_currency && entry.date == entry_date &&
        entry.amount.negative? && entry.amount.abs == native_amount &&
        entry.transaction? && entry.transaction.kind == "standard" &&
        !entry.transaction.pending? && !entry.excluded? && !entry.split_parent? &&
        !entry.scheduled? && (!rate_snapshot || (
          rate_snapshot.family_id == family_id && rate_snapshot.from_currency == native_currency &&
          rate_snapshot.to_currency == funding_plan.currency &&
          Decimal.money!((native_amount * rate_snapshot.rate).round(4), positive: true) == applied_amount))
    rescue ArgumentError
      false
    end

    def payload_for(viewer)
      if viewer&.id == funding_plan.student_user_id &&
          viewer.family_id == family_id && viewer.active?
        return { id: id, funding_plan_id: funding_plan_id, entry_id: entry_id,
          due_on: due_on.iso8601, native_currency: native_currency,
          native_amount: native_amount.to_s("F"), applied_amount: applied_amount.to_s("F"),
          entry_date: entry_date.iso8601, consistent: consistent?, created_at: created_at.iso8601(6) }
      end
      unless viewer&.id == funding_plan.parent_user_id && funding_plan.relationship.status == "active" &&
          Grant.allowed?(viewer, funding_plan.project, "transaction_details")
        raise ActiveRecord::RecordNotFound
      end
      { id: id, funding_plan_id: funding_plan_id,
        due_on: due_on.iso8601, native_currency: native_currency,
        native_amount: native_amount.to_s("F"), applied_amount: applied_amount.to_s("F"),
        entry_date: entry_date.iso8601 }
    end

    private
      def valid_ledger_provenance
        unless funding_plan && entry && actor && family_id == funding_plan.family_id &&
            actor_id == funding_plan.student_user_id && entry.account.family_id == family_id &&
            entry.account_id == funding_plan.destination_account_id &&
            entry.currency == native_currency && entry.date == entry_date &&
            entry.amount.negative? && entry.amount.abs == native_amount &&
            (!rate_snapshot || rate_snapshot.family_id == family_id)
          errors.add(:base, "Invalid funding receipt provenance")
        end
      end
  end
end
