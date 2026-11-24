module Abroa
  # Approved changes to contractual liability; cash-paid scholarships remain
  # ordinary real incoming ledger entries, never this offset model.
  class FeeAdjustment < ApplicationRecord
    self.table_name = "abroa_fee_adjustments"
    Conflict = Class.new(StandardError)
    DEDUCTIONS = %w[waiver scholarship_offset].freeze
    KINDS = (DEDUCTIONS + %w[surcharge]).freeze

    belongs_to :family
    belongs_to :actor, class_name: "User"
    belongs_to :fee_plan, class_name: "Abroa::FeePlan"
    belongs_to :fee_installment, class_name: "Abroa::FeeInstallment", optional: true

    validates :kind, inclusion: { in: KINDS }
    validates :status, inclusion: { in: %w[approved void] }
    validates :reason, presence: true, length: { maximum: 500 }
    validates :amount, numericality: { greater_than: 0 }
    validate :valid_tenant

    def self.for_user(user)
      where(family_id: user.family_id, fee_plan_id: FeePlan.for_user(user).select(:id))
    end

    def self.apply_for!(user, plan_id, kind:, amount:, reason:, key:, installment_id: nil)
      value = Decimal.money!(amount, positive: true)
      raise ArgumentError, "Invalid adjustment kind" unless KINDS.include?(kind)
      raise ArgumentError, "Reason required" unless reason.is_a?(String) && reason.strip.present? && reason.length <= 500
      raise ArgumentError, "Invalid idempotency key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      payload = { kind: kind, amount: value.to_s("F"), reason: reason.strip, installment_id: installment_id }
      digest = Digest::SHA256.hexdigest([ user.id, plan_id, key ].join(":"))
      request = Digest::SHA256.hexdigest(payload.to_json)
      StudyProject.with_actor(user) do
        plan = FeePlan.for_user(user).lock.find(plan_id)
        plan.project.ensure_writable!
        raise FeePlan::Conflict, "Cannot change a cancelled fee" if plan.status != "active"
        if (existing = where(family: user.family, operation_key: digest).first)
          raise Conflict, "Adjustment key was reused with changed data" unless
            existing.fee_plan_id == plan.id && existing.request_digest == request
          next existing
        end
        installment = installment_id ? plan.installments.lock.find(installment_id) : nil
        raise FeePlan::Conflict, "Cannot adjust a cancelled installment" if installment&.state == "cancelled"
        record = create!(family: user.family, actor: user, fee_plan: plan,
          fee_installment: installment, kind: kind, amount: value, currency: plan.currency,
          reason: reason.strip, operation_key: digest, request_digest: request)
        check_balances!(plan, installment)
        PlanningAuditEvent.record!(actor: user, event_type: "fee_adjustment.approved", resource: record,
          safe_data: { fee_plan_id: plan.id, installment_id: installment_id, kind: kind,
            amount: value.to_s("F"), currency: plan.currency })
        record
      end
    end

    def self.void_for!(user, id:)
      StudyProject.with_actor(user) do
        item = for_user(user).lock.find(id)
        item.fee_plan.project.ensure_writable!
        raise Conflict, "Adjustment is already void" unless item.status == "approved"
        item.update!(status: "void", voided_at: Time.current)
        check_balances!(item.fee_plan, item.fee_installment)
        PlanningAuditEvent.record!(actor: user, event_type: "fee_adjustment.void", resource: item)
        item
      end
    end

    def self.check_balances!(plan, installment)
      raise Conflict, "Fee discount cannot exceed approved gross amount" if plan.amount_due.negative?
      raise Conflict, "Fee liability is lower than confirmed payments" if plan.paid_amount > plan.amount_due
      if installment && installment.net_amount < installment.paid_amount
        raise Conflict, "Installment net amount below paid value"
      end
      total = plan.installments.where.not(state: "cancelled").to_a.sum(BigDecimal("0"), &:net_amount)
      raise Conflict, "Installments exceed the net fee plan" if total > plan.amount_due
    end

    def payload
      { id: id, fee_plan_id: fee_plan_id, installment_id: fee_installment_id,
        kind: kind, status: status, amount: amount.to_s("F"), currency: currency,
        reason: reason, occurred_at: created_at.iso8601(6), voided_at: voided_at&.iso8601(6) }
    end

    private
      def valid_tenant
        unless family && actor && fee_plan && family_id == actor.family_id &&
            family_id == fee_plan.family_id &&
            (!fee_installment || fee_installment.fee_plan_id == fee_plan_id)
          errors.add(:base, "Adjustment family or installment does not match")
        end
      end
  end
end
