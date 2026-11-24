module Abroa
  class FeeInstallment < ApplicationRecord
    self.table_name = "abroa_fee_installments"
    FIELDS = %i[name due_on gross_amount discount_amount state].freeze

    belongs_to :family
    belongs_to :fee_plan, class_name: "Abroa::FeePlan"
    belongs_to :recurring_occurrence, optional: true
    has_many :settlements, class_name: "Abroa::FeeSettlement", foreign_key: :fee_installment_id
    has_many :reminder_events, class_name: "Abroa::FeeReminderEvent", foreign_key: :fee_installment_id
    has_many :adjustments, class_name: "Abroa::FeeAdjustment", foreign_key: :fee_installment_id

    validates :name, :due_on, presence: true
    validates :state, inclusion: { in: %w[draft confirmed cancelled] }
    validate :valid_amounts_dates_and_scope

    def self.for_user(user)
      where(family_id: user.family_id, fee_plan_id: FeePlan.for_user(user).select(:id))
    end

    def self.schedule_for!(user, plan_id, attributes:, key: nil)
      values = checked(attributes)
      StudyProject.with_actor(user) do
        plan = FeePlan.for_user(user).lock.find(plan_id)
        plan.project.ensure_writable!
        raise FeePlan::Conflict, "Cancelled fee" if plan.status == "cancelled"
        if key
          raise ArgumentError, "Invalid installment key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
          digest = Digest::SHA256.hexdigest(key)
          request = Digest::SHA256.hexdigest(JSON.generate(values.deep_stringify_keys.sort.to_h))
          if (existing = plan.installments.find_by(creation_key_digest: digest))
            raise FeePlan::Conflict, "Installment key changed" unless existing.creation_request_digest == request
            next existing
          end
        end
        record = plan.installments.create!(values.merge(family: user.family,
          creation_key_digest: digest, creation_request_digest: request))
        PlanningAuditEvent.record!(actor: user, event_type: "fee_installment.created", resource: record)
        record
      end
    end

    # Import existing Sure bill occurrences as fee liabilities, never as
    # bank transactions. The recurring engine remains authoritative for the
    # schedule; this creates a stable project snapshot of its due amount.
    def self.import_recurring_for!(user, plan_id, from_on:, through_on:)
      begin
        first, last = Date.iso8601(from_on), Date.iso8601(through_on)
      rescue Date::Error, TypeError
        raise ArgumentError, "Expected ISO recurrence dates"
      end
      if last < first || (last - first).to_i > 366 || first.year < 2000
        raise ArgumentError, "Invalid recurring fee import window"
      end
      StudyProject.with_actor(user) do
        plan = FeePlan.for_user(user).lock.find(plan_id)
        plan.project.ensure_writable!
        raise FeePlan::Conflict, "Cancelled fee" if plan.status == "cancelled"
        recurring = plan.recurring_transaction
        raise ArgumentError, "Fee has no linked Sure recurring bill" unless recurring
        raise ActiveRecord::RecordNotFound unless recurring.family_id == user.family_id &&
          recurring.account_id &&
          user.family.accounts.accessible_by(user).where(id: recurring.account_id).exists?
        raise ArgumentError, "Recurring bill currency differs from the fee" unless recurring.currency == plan.currency
        occurrences = recurring.recurring_occurrences.where(due_on: first..last)
          .order(:due_on, :id).limit(101).to_a
        raise ArgumentError, "Too many recurring occurrences for one import" if occurrences.size > 100
        occurrences.filter_map do |occurrence|
          next if occurrence.skipped?
          due_date = occurrence.effective_due_on
          next if due_date < first || due_date > last
          if due_date < plan.project.start_on || (plan.project.end_on && due_date > plan.project.end_on)
            raise ArgumentError, "Recurring fee is outside study dates"
          end
          raise ArgumentError, "Recurring occurrence currency changed" unless occurrence.currency == plan.currency
          existing = find_by(recurring_occurrence_id: occurrence.id)
          if existing
            raise FeePlan::Conflict, "Sure occurrence assigned to another fee" unless existing.fee_plan_id == plan.id
            next existing
          end
          amount = Decimal.money!(occurrence.resolved_expected_amount, nonnegative: true)
          record = plan.installments.create!(
            family: user.family, recurring_occurrence: occurrence,
            name: "#{plan.name} - #{due_date.iso8601}", due_on: due_date,
            gross_amount: amount, discount_amount: BigDecimal("0"), state: "confirmed"
          )
          PlanningAuditEvent.record!(actor: user, event_type: "fee_installment.imported", resource: record,
            safe_data: { recurring_occurrence_id: occurrence.id })
          record
        end
      end
    end

    def self.change_for!(user, id, version:, attributes:)
      values = checked(attributes)
      StudyProject.with_actor(user) do
        installment = for_user(user).lock.find(id)
        installment.fee_plan.project.ensure_writable!
        raise FeePlan::Conflict, "Installment changed" unless version.is_a?(Integer) && version == installment.lock_version
        raise FeePlan::Conflict, "Fee is cancelled" if installment.fee_plan.status == "cancelled"
        if installment.recurring_occurrence_id && values.key?(:due_on)
          raise FeePlan::Conflict, "Due date of a linked Sure occurrence cannot be edited"
        end
        raise FeePlan::Conflict, "Cannot cancel a paid installment" if values[:state] == "cancelled" && installment.settlements.exists?
        installment.update!(values)
        if installment.settlements.exists? && installment.net_amount < installment.paid_amount
          raise FeePlan::Conflict, "Outstanding fee cannot become negative"
        end
        PlanningAuditEvent.record!(actor: user, event_type: "fee_installment.updated", resource: installment)
        installment
      end
    end

    def self.checked(attributes)
      values = attributes.symbolize_keys
      raise ArgumentError, "Unknown installment field" unless (values.keys - FIELDS).empty?
      values
    end

    def net_amount
      approved = adjustments.where(status: "approved")
      gross_amount - discount_amount -
        approved.where(kind: %w[waiver scholarship_offset]).sum(:amount) +
        approved.where(kind: "surcharge").sum(:amount)
    end

    def paid_amount
      settlements.sum("CASE WHEN kind = 'payment' THEN fee_amount ELSE -fee_amount END").to_d
    end

    def outstanding_amount
      return BigDecimal("0") if state == "cancelled"
      [ BigDecimal("0"), net_amount - paid_amount ].max
    end

    def payment_status
      return "cancelled" if state == "cancelled"
      return "draft" if state == "draft"
      return "paid" if paid_amount >= net_amount
      return "partially_paid" if paid_amount.positive?
      due_on < Date.current ? "overdue" : "pending"
    end

    def readable_for?(user)
      settlements.count == settlements.visible_to(user).count
    end

    def payload_for(user)
      result = payload
      unless readable_for?(user)
        result[:paid_amount] = nil
        result[:outstanding_amount] = nil
        result[:payment_status] = "unavailable"
        result[:incomplete] = true
      else
        result[:incomplete] = settlements.any? { |entry| !entry.consistent? }
      end
      result
    end

    def payload
      { id: id, fee_plan_id: fee_plan_id, name: name, due_on: due_on.iso8601, state: state,
        gross_amount: gross_amount.to_s("F"), discount_amount: discount_amount.to_s("F"),
        net_amount: net_amount.to_s("F"), paid_amount: paid_amount.to_s("F"),
        outstanding_amount: outstanding_amount.to_s("F"), payment_status: payment_status,
        recurring_occurrence_id: recurring_occurrence_id, lock_version: lock_version }
    end

    private
      def valid_amounts_dates_and_scope
        begin
          gross = Decimal.money!(gross_amount, nonnegative: true)
          discount = Decimal.money!(discount_amount, nonnegative: true)
          errors.add(:discount_amount, :invalid) if discount > gross
        rescue ArgumentError
          errors.add(:base, "Invalid installment amounts")
        end
        if recurring_occurrence &&
            (recurring_occurrence.family_id != family_id ||
             fee_plan&.recurring_transaction_id != recurring_occurrence.recurring_transaction_id)
          errors.add(:recurring_occurrence, :invalid)
        end
        unless fee_plan && family_id == fee_plan.family_id && due_on &&
            due_on >= fee_plan.project.start_on && (!fee_plan.project.end_on || due_on <= fee_plan.project.end_on)
          errors.add(:base, "Installment outside study project")
          return
        end
        net = net_amount if gross_amount && discount_amount
        scheduled = fee_plan.installments.where.not(state: "cancelled")
        scheduled = scheduled.where.not(id: id) if persisted?
        if net && state != "cancelled" &&
            scheduled.to_a.sum(BigDecimal("0"), &:net_amount) + net > fee_plan.amount_due
          errors.add(:base, "Scheduled installments exceed fee net amount")
        end
      end
  end
end
