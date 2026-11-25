module Abroa
  # Student-requested changes to parental funding; no edits are effective
  # before the parent accepts. Never creates cash, ledger entries or transfers.
  class FundingSuggestion < ApplicationRecord
    self.table_name = "abroa_funding_suggestions"
    Conflict = Class.new(StandardError)
    FIELDS = %i[name kind amount currency frequency scheduled_on ends_on].freeze

    belongs_to :family
    belongs_to :funding_plan, class_name: "Abroa::FundingPlan"
    belongs_to :student_user, class_name: "User"
    belongs_to :resolved_by, class_name: "User", optional: true

    validates :status, inclusion: { in: %w[pending accepted rejected cancelled] }
    validates :expected_version, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
    validate :valid_scope_and_payload

    def self.for_actor(actor)
      where(funding_plan_id: FundingPlan.for_actor(actor).select(:id))
    end

    def self.create_for!(student, plan_id, attributes:, key:)
      fields = checked!(attributes)
      raise ArgumentError, "Invalid suggestion key" unless key.is_a?(String) &&
        key.present? && key.bytesize <= 128
      key_digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest(
        JSON.generate([ plan_id, fields.deep_stringify_keys.sort.to_h ]))
      StudyProject.with_actor(student) do
        plan = FundingPlan.for_student(student).lock.find(plan_id)
        old = where(student_user_id: student.id, creation_key_digest: key_digest).first
        if old
          raise Conflict, "Suggestion key reused" unless old.creation_request_digest == request_digest
          next old
        end
        raise Conflict, "Plan cannot be changed" unless %w[planned confirmed partially_received].include?(plan.status)
        raise ActiveRecord::RecordNotFound unless plan.relationship.status == "active" &&
          plan.relationship.student_user_id == student.id
        raise Conflict, "Pending suggestion already exists" if
          where(funding_plan_id: plan.id, status: "pending").exists?
        ensure_compatible_change!(plan, fields)
        record = create!(family: plan.family, funding_plan: plan, student_user: student,
          payload: fields, expected_version: plan.lock_version, status: "pending",
          creation_key_digest: key_digest, creation_request_digest: request_digest)
        PlanningAuditEvent.record!(actor: student, event_type: "funding_suggestion.created", resource: record,
          safe_data: { funding_plan_id: plan.id })
        record
      end
    end

    def self.accept_for!(parent, id, version:)
      parent.with_lock do
        record = where(id: id).lock.find(id)
        next record if record.status == "accepted" && record.funding_plan.parent_user_id == parent.id &&
          record.funding_plan.relationship.status == "active"
        plan = FundingPlan.where(id: record.funding_plan_id, parent_user_id: parent.id).lock.first!
        raise ActiveRecord::RecordNotFound unless plan.relationship.status == "active" &&
          plan.relationship.parent_family_id == parent.family_id && parent.active?
        raise Conflict, "Suggestion has changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Suggestion is no longer pending" unless record.status == "pending"
        raise Conflict, "Funding plan changed" unless plan.lock_version == record.expected_version &&
          %w[planned confirmed partially_received].include?(plan.status)
        fields = checked!(record.payload)
        ensure_compatible_change!(plan, fields)
        plan.assign_attributes(fields)
        raise ActiveRecord::RecordInvalid, plan unless plan.valid?
        raise Conflict, "Adjusted funding is less than actual received" if
          plan.planned_total < plan.received_total
        plan.save!
        plan.refresh_after_receipt! if plan.status != "planned"
        record.update!(status: "accepted", resolved_at: Time.current, resolved_by: parent)
        PlanningAuditEvent.record!(actor: parent, event_type: "funding_suggestion.accepted", resource: record,
          safe_data: { funding_plan_id: plan.id })
        record
      end
    end

    def self.reject_for!(parent, id, version:)
      parent.with_lock do
        record = where(id: id).lock.find(id)
        plan = FundingPlan.where(id: record.funding_plan_id, parent_user_id: parent.id).first!
        raise ActiveRecord::RecordNotFound unless plan.relationship.status == "active" &&
          plan.relationship.parent_family_id == parent.family_id
        raise Conflict, "Suggestion changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Suggestion no longer pending" unless record.status == "pending"
        record.update!(status: "rejected", resolved_by: parent, resolved_at: Time.current)
        PlanningAuditEvent.record!(actor: parent, event_type: "funding_suggestion.rejected", resource: record)
        record
      end
    end

    def self.cancel_for!(student, id, version:)
      StudyProject.with_actor(student) do
        record = where(student_user_id: student.id, family_id: student.family_id).lock.find(id)
        raise Conflict, "Suggestion changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Suggestion no longer pending" unless record.status == "pending"
        record.update!(status: "cancelled", resolved_by: student, resolved_at: Time.current)
        PlanningAuditEvent.record!(actor: student, event_type: "funding_suggestion.cancelled", resource: record)
        record
      end
    end

    def self.checked!(attributes)
      fields = attributes.to_h.symbolize_keys
      raise ArgumentError, "Invalid suggestion payload" if fields.empty? ||
        (fields.keys - FIELDS).any? || JSON.generate(fields).bytesize > 4_096
      fields
    end

    def self.ensure_compatible_change!(plan, fields)
      if plan.receipts.exists? && (fields.keys & %i[currency frequency scheduled_on ends_on]).any?
        raise Conflict, "Historical funded periods or currency cannot change"
      end
      raise Conflict, "Funding plan archived" if plan.project.status == "archived"
    end

    def payload_for(actor)
      raise ActiveRecord::RecordNotFound unless self.class.for_actor(actor).where(id: id).exists?
      { id: id, funding_plan_id: funding_plan_id, payload: payload, status: status,
        expected_version: expected_version, lock_version: lock_version,
        resolved_at: resolved_at&.iso8601 }
    end

    private
      def valid_scope_and_payload
        errors.add(:family, :invalid) unless funding_plan && student_user &&
          family_id == funding_plan.family_id && student_user_id == funding_plan.student_user_id
        begin
          self.class.checked!(payload)
        rescue ArgumentError
          errors.add(:payload, :invalid)
        end
      end
  end
end
