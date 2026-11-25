module Abroa
  # Parent's claim that money was sent. Unverified, never booked as actual cash.
  # A posted student-ledger Entry is still required for FundingReceipt.match_for!.
  class FundingNotice < ApplicationRecord
    self.table_name = "abroa_funding_notices"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :funding_plan, class_name: "Abroa::FundingPlan"
    belongs_to :actor, class_name: "User"

    validates :status, inclusion: { in: %w[active revoked] }
    validates :amount, numericality: { greater_than: 0 }
    validate :valid_source

    def self.create_for!(parent, plan_id, amount:, reported_on:, key:)
      value = Decimal.money!(amount, positive: true)
      date = reported_on.is_a?(Date) ? reported_on : Date.iso8601(reported_on.to_s)
      raise ArgumentError, "Notice must be dated on or before today" if date > Date.current
      raise ArgumentError, "Invalid notice key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      digest = Digest::SHA256.hexdigest(key)
      request = Digest::SHA256.hexdigest([ plan_id, value.to_s("F"), date.iso8601 ].join(":"))
      parent.with_lock do
        plan = FundingPlan.where(parent_user_id: parent.id).lock.find(plan_id)
        old = where(funding_plan_id: plan.id, creation_key_digest: digest).first
        if old
          raise Conflict, "Notice key changed" unless old.creation_request_digest == request
          next old
        end
        raise ActiveRecord::RecordNotFound unless plan.relationship.status == "active" &&
          plan.relationship.parent_family_id == parent.family_id
        raise Conflict, "Cannot report on an inactive plan" unless
          %w[confirmed partially_received].include?(plan.status)
        raise Conflict, "Notice exceeds funding plan" if value + plan.reported_sent_total > plan.planned_total
        notice = create!(family: plan.family, funding_plan: plan, actor: parent,
          amount: value, currency: plan.currency, reported_on: date,
          creation_key_digest: digest, creation_request_digest: request)
        PlanningAuditEvent.record!(actor: parent, event_type: "funding_notice.reported", resource: notice,
          safe_data: { funding_plan_id: plan.id, amount: value.to_s("F"), currency: plan.currency })
        notice
      end
    end

    def self.revoke_for!(parent, id, version:)
      parent.with_lock do
        notice = where(actor_id: parent.id).lock.find(id)
        raise Conflict, "Notice changed" unless version.is_a?(Integer) && notice.lock_version == version
        raise Conflict, "Notice already revoked" unless notice.status == "active"
        raise ActiveRecord::RecordNotFound unless notice.funding_plan.relationship.status == "active"
        notice.update!(status: "revoked")
        PlanningAuditEvent.record!(actor: parent, event_type: "funding_notice.revoked", resource: notice)
        notice
      end
    end

    def payload_for(viewer)
      raise ActiveRecord::RecordNotFound unless viewer&.active? &&
        [ funding_plan.student_user_id, actor_id ].include?(viewer.id)
      if viewer.id == actor_id && funding_plan.relationship.status != "active"
        raise ActiveRecord::RecordNotFound
      end
      { id: id, funding_plan_id: funding_plan_id, amount: amount.to_s("F"),
        currency: currency, reported_on: reported_on.iso8601,
        status: status, lock_version: lock_version }
    end

    private
      def valid_source
        errors.add(:base, "Notice does not belong to parent-to-student plan") unless funding_plan && actor &&
          family_id == funding_plan.family_id &&
          actor_id == funding_plan.parent_user_id && currency == funding_plan.currency
      end
  end
end
