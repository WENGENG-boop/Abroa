module Abroa
  class Proposal < ApplicationRecord
    self.table_name = "abroa_proposals"
    Conflict = Class.new(StandardError)
    LIFETIME = 30.days
    OPERATIONS = %w[budget_create budget_update study_project_update].freeze
    BUDGET_FIELDS = %i[name start_on end_on currency limit_amount parent_id period_id category_id
      rollover_enabled warning_threshold].freeze

    belongs_to :family
    belongs_to :relationship, class_name: "Abroa::Relationship"
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :actor, class_name: "User"
    belongs_to :resolved_by, class_name: "User", optional: true
    belongs_to :planning_draft, class_name: "Abroa::PlanningDraft", optional: true

    validates :operation, inclusion: { in: OPERATIONS }
    validates :status, inclusion: { in: %w[draft pending accepted rejected cancelled expired] }
    validate :valid_scope_and_payload

    def self.for_actor(user)
      raise ActiveRecord::RecordNotFound unless user&.active?
      own_parent_links = Relationship.where(parent_user_id: user.id,
        parent_family_id: user.family_id, status: "active").select(:id)
      allowed_projects = Grant.scoped_to_parent(user, capability: "propose")
        .where(resource_kind: "project", resource_id: nil).select(:project_id)
      own_student_links = Relationship.where(student_user_id: user.id,
        student_family_id: user.family_id).select(:id)
      where(actor_id: user.id, relationship_id: own_parent_links, project_id: allowed_projects)
        .or(where(relationship_id: own_student_links, family_id: user.family_id))
    end

    def self.create_for!(parent, relationship_id:, project_id:, operation:, target_id:, payload:, expected_version:, key:,
      planning_draft_id: nil)
      raise ArgumentError, "Invalid proposal" unless OPERATIONS.include?(operation) &&
        expected_version.is_a?(Integer) && expected_version >= 0 &&
        key.is_a?(String) && key.present? && key.bytesize <= 128 &&
        UuidFormat.valid?(target_id)
      fields = checked_payload!(operation, payload)
      request = Digest::SHA256.hexdigest(JSON.generate({
        relationship_id: relationship_id, project_id: project_id, target_id: target_id,
        operation: operation, payload: fields, expected_version: expected_version,
        planning_draft_id: planning_draft_id
      }.deep_stringify_keys.sort.to_h))
      parent.with_lock do
        raise ActiveRecord::RecordNotFound unless parent.active? && !parent.guest? &&
          Profile.for_user(parent).parent_enabled?
        old = where(actor: parent, creation_key_digest: Digest::SHA256.hexdigest(key)).first
        if old
          raise Conflict, "Proposal request changed" unless old.creation_request_digest == request
          next old
        end
        relation = Relationship.where(parent_user_id: parent.id, parent_family_id: parent.family_id, status: "active").lock.find(relationship_id)
        project = StudyProject.where(id: project_id, owner_id: relation.student_user_id,
          family_id: relation.student_family_id).first!
        raise Conflict, "Project is archived" if project.status == "archived"
        grant = Grant.scoped_to_parent(parent, capability: "propose").where(
          relationship_id: relation.id, project_id: project.id, resource_kind: "project", resource_id: nil).lock.first!
        raise Conflict, "Grant expired" unless grant.status == "active" &&
          (grant.expires_at.nil? || grant.expires_at > Time.current)
        target = operation == "budget_update" ?
          BudgetNode.where(id: target_id, project_id: project.id, family_id: project.family_id).first! : project
        raise ActiveRecord::RecordNotFound if operation != "budget_update" && target_id != project.id
        raise Conflict, "Planning target changed" unless target.lock_version == expected_version
        draft = nil
        if planning_draft_id
          draft = PlanningDraft.for_user(parent).lock.find(planning_draft_id)
          expected_kind = operation == "study_project_update" ? "study_project" : "budget"
          raise Conflict, "Draft already proposed or cancelled" unless draft.status == "draft"
          raise ArgumentError, "Draft payload or kind differs from proposal" unless
            draft.kind == expected_kind && draft.payload == fields.stringify_keys
        end
        record = create!(family: project.family, relationship: relation, project: project,
          actor: parent, operation: operation, target_id: target_id, payload: fields,
          planning_draft: draft, expected_version: expected_version, expires_at: Time.current + LIFETIME,
          creation_key_digest: Digest::SHA256.hexdigest(key), creation_request_digest: request)
        draft&.update!(status: "submitted")
        PlanningAuditEvent.record!(actor: parent, event_type: "proposal.created", resource: record,
          safe_data: { project_id: project.id, operation: operation })
        record
      end
    end

    def self.submit_for!(parent, id, version:)
      transition_for!(parent, id, version: version, from: "draft", to: "pending", event: "submitted")
    end

    def self.cancel_for!(parent, id, version:)
      parent.with_lock do
        record = where(actor_id: parent.id).lock.find(id)
        raise Conflict, "Proposal changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Cannot cancel" unless %w[draft pending].include?(record.status)
        raise ActiveRecord::RecordNotFound unless record.relationship.status == "active" &&
          Grant.allowed?(parent, record.project, "propose")
        record.update!(status: "cancelled", resolved_by: parent, resolved_at: Time.current)
        record.planning_draft&.update!(status: "cancelled")
        PlanningAuditEvent.record!(actor: parent, event_type: "proposal.cancelled", resource: record)
        record
      end
    end

    def self.reject_for!(student, id, version:)
      StudyProject.with_actor(student) do
        record = where(id: id, relationship_id: Relationship.where(student_user_id: student.id).select(:id)).lock.first!
        raise Conflict, "Proposal changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Proposal not pending" unless record.status == "pending" && record.expires_at > Time.current
        record.update!(status: "rejected", resolved_by: student, resolved_at: Time.current)
        record.planning_draft&.update!(status: "rejected")
        PlanningAuditEvent.record!(actor: student, event_type: "proposal.rejected", resource: record)
        record
      end
    end

    def self.accept_for!(student, id, version:)
      StudyProject.with_actor(student) do
        record = where(id: id, relationship_id: Relationship.where(student_user_id: student.id).select(:id)).lock.first!
        next record if record.status == "accepted"
        raise Conflict, "Proposal changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Proposal no longer pending" unless record.status == "pending" &&
          record.expires_at > Time.current
        relation = Relationship.where(id: record.relationship_id, student_user_id: student.id, status: "active").lock.first!
        raise Conflict, "Relationship changed" unless relation.status == "active"
        parent = relation.parent_user
        grant = Grant.scoped_to_parent(parent, capability: "propose").where(
          relationship_id: relation.id, project_id: record.project_id,
          resource_kind: "project", resource_id: nil).lock.first
        raise Conflict, "Proposal authorization revoked" unless grant &&
          grant.status == "active" && (grant.expires_at.nil? || grant.expires_at > Time.current)
        project = StudyProject.for_user(student).lock.find(record.project_id)
        project.ensure_writable!
        fields = checked_payload!(record.operation, record.payload)
        applied = case record.operation
        when "budget_update"
          target = BudgetNode.for_user(student).where(project_id: project.id).lock.find(record.target_id)
          raise Conflict, "Budget version changed" unless target.lock_version == record.expected_version
          before = target.version_data
          target.update!(fields)
          target.version_for!(student, kind: "parent_proposal", before: before)
          PlanningAuditEvent.record!(actor: student, event_type: "budget.proposal_applied", resource: target,
            safe_data: { proposal_id: record.id, parent_id: parent.id })
          target
        when "budget_create"
          raise Conflict, "Project version changed" unless project.id == record.target_id &&
            project.lock_version == record.expected_version
          BudgetNode.create_for!(student, project.id, attributes: fields, key: "proposal-budget-#{record.id}")
        when "study_project_update"
          raise Conflict, "Project version changed" unless project.id == record.target_id &&
            project.lock_version == record.expected_version
          StudyProject.change_for!(student, project.id, version: project.lock_version, attributes: fields)
        else
          raise Conflict, "Unrecognized planning operation"
        end
        record.update!(status: "accepted", applied_resource_id: applied.id,
          resolved_by: student, resolved_at: Time.current)
        record.planning_draft&.update!(status: "accepted")
        PlanningAuditEvent.record!(actor: student, event_type: "proposal.accepted", resource: record)
        record
      end
    end

    def self.checked_payload!(operation, fields)
      raise ArgumentError, "Unknown proposal operation" unless OPERATIONS.include?(operation)
      value = fields.to_h.symbolize_keys
      permitted = operation == "study_project_update" ? StudyProject::FIELDS : BUDGET_FIELDS
      permitted = %i[name limit_amount warning_threshold] if operation == "budget_update"
      raise ArgumentError, "Invalid proposal payload" if value.empty? || value.size > 12 ||
        (value.keys - permitted).any? || JSON.generate(value).bytesize > 4_096
      if operation == "budget_create"
        raise ArgumentError, "Incomplete budget proposal" unless
          %i[name currency start_on end_on limit_amount].all? { |field| value.key?(field) }
      end
      operation == "study_project_update" ? value : BudgetNode.checked(value)
    end

    def payload_data
      attributes.slice("id", "relationship_id", "project_id", "operation", "target_id",
        "payload", "expected_version", "status", "expires_at", "resolved_at",
        "applied_resource_id", "lock_version")
    end

    private
      def self.transition_for!(parent, id, version:, from:, to:, event:)
        parent.with_lock do
          record = where(actor_id: parent.id).lock.find(id)
          raise Conflict, "Proposal changed" unless version.is_a?(Integer) && record.lock_version == version
          raise Conflict, "Proposal state changed" unless record.status == from && record.expires_at > Time.current
          relation = Relationship.where(id: record.relationship_id, parent_user_id: parent.id, status: "active").lock.first!
          raise Conflict, "Proposal authorization lost" unless Grant.allowed?(parent, record.project, "propose")
          record.update!(status: to)
          PlanningAuditEvent.record!(actor: parent, event_type: "proposal.#{event}", resource: record)
          record
        end
      end

      def valid_scope_and_payload
        return unless relationship && project && actor
        errors.add(:family, :invalid) unless family_id == relationship.student_family_id &&
          family_id == project.family_id && project.owner_id == relationship.student_user_id &&
          actor_id == relationship.parent_user_id && relationship.parent_family_id == actor.family_id
        begin
          self.class.checked_payload!(operation, payload)
        rescue ArgumentError
          errors.add(:payload, :invalid)
        end
      end
  end
end
