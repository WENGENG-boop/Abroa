module Abroa
  class FeeInstallment < ApplicationRecord
    self.table_name = "abroa_fee_installments"
    FIELDS = %i[name due_on gross_amount discount_amount state].freeze

    belongs_to :family
    belongs_to :fee_plan, class_name: "Abroa::FeePlan"
    has_many :settlements, class_name: "Abroa::FeeSettlement", foreign_key: :fee_installment_id

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

    def self.change_for!(user, id, version:, attributes:)
      values = checked(attributes)
      StudyProject.with_actor(user) do
        installment = for_user(user).lock.find(id)
        installment.fee_plan.project.ensure_writable!
        raise FeePlan::Conflict, "Installment changed" unless version.is_a?(Integer) && version == installment.lock_version
        raise FeePlan::Conflict, "Fee is cancelled" if installment.fee_plan.status == "cancelled"
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
      gross_amount - discount_amount
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
        outstanding_amount: outstanding_amount.to_s("F"), payment_status: payment_status, lock_version: lock_version }
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
        unless fee_plan && family_id == fee_plan.family_id && due_on &&
            due_on >= fee_plan.project.start_on && (!fee_plan.project.end_on || due_on <= fee_plan.project.end_on)
          errors.add(:base, "Installment outside study project")
          return
        end
        net = gross_amount - discount_amount if gross_amount && discount_amount
        scheduled = fee_plan.installments.where.not(state: "cancelled")
        scheduled = scheduled.where.not(id: id) if persisted?
        if net && state != "cancelled" &&
            scheduled.sum("gross_amount - discount_amount") + net > fee_plan.amount_due
          errors.add(:base, "Scheduled installments exceed fee net amount")
        end
      end
  end
end
