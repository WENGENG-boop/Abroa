module Abroa
  class Grant < ApplicationRecord
    self.table_name = "abroa_grants"
    Conflict = Class.new(StandardError)
    CAPABILITIES = %w[summary account_balance transaction_details budget_read fees_read
      forecasts_read propose budget_manage fees_manage pool_manage].freeze

    belongs_to :family
    belongs_to :relationship, class_name: "Abroa::Relationship"
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :actor, class_name: "User"

    validates :capability, inclusion: { in: CAPABILITIES }
    validates :status, inclusion: { in: %w[active revoked expired] }
    validate :student_owned_scope
    validate :future_expiry, if: -> { new_record? && expires_at.present? }

    def self.create_for!(student, relationship_id, project_id:, capability:, key:, expires_at: nil,
      resource_kind: "project", resource_id: nil)
      raise ArgumentError, "Invalid grant capability" unless CAPABILITIES.include?(capability)
      raise ArgumentError, "Invalid grant key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      raise ArgumentError, "Invalid grant resource" unless (resource_kind == "project" && resource_id.nil?) ||
        (%w[budget_node fee_plan fund_pool].include?(resource_kind) && UuidFormat.valid?(resource_id))
      key_digest = Digest::SHA256.hexdigest(key)
      request = Digest::SHA256.hexdigest([ project_id, capability, resource_kind, resource_id, expires_at&.iso8601 ].join(":"))
      StudyProject.with_actor(student) do
        relation = Relationship.where(student_user_id: student.id, status: "active").lock.find(relationship_id)
        raise Conflict, "Parent link is no longer active" unless relation.active_for?(student)
        project = StudyProject.find_for!(student, project_id)
        project.ensure_writable!
        old = where(actor_id: student.id, relationship_id: relation.id, creation_key_digest: key_digest).first
        if old
          raise Conflict, "Grant request changed" unless old.creation_request_digest == request
          next old
        end
        resource_model = { "budget_node" => BudgetNode, "fee_plan" => FeePlan,
          "fund_pool" => FundPool }[resource_kind]
        if resource_model && !resource_model.where(id: resource_id, project_id: project.id, family_id: student.family_id).exists?
          raise ActiveRecord::RecordNotFound
        end
        relation.grants.where(project_id: project.id, capability: capability, resource_kind: resource_kind,
          resource_id: resource_id, status: "active")
          .where("expires_at <= ?", Time.current).update_all(status: "expired", updated_at: Time.current)
        if relation.grants.exists?(project_id: project.id, capability: capability,
            resource_kind: resource_kind, resource_id: resource_id, status: "active")
          raise Conflict, "Capability already granted"
        end
        grant = create!(family: student.family, actor: student, relationship: relation, project: project,
          capability: capability, resource_kind: resource_kind, resource_id: resource_id,
          expires_at: expires_at, status: "active", creation_key_digest: key_digest,
          creation_request_digest: request)
        PlanningAuditEvent.record!(actor: student, event_type: "grant.created", resource: grant,
          safe_data: { capability: grant.capability, project_id: project.id })
        grant
      end
    end

    def self.revoke_for!(student, relationship_id, grant_id, version:)
      StudyProject.with_actor(student) do
        relation = Relationship.where(student_user_id: student.id, status: "active").lock.find(relationship_id)
        grant = relation.grants.lock.find(grant_id)
        raise Conflict, "Grant version changed" unless version.is_a?(Integer) && grant.lock_version == version
        raise Conflict, "Grant already revoked or expired" unless grant.status == "active"
        grant.update!(status: "revoked", revoked_at: Time.current, version: grant.version + 1)
        PlanningAuditEvent.record!(actor: student, event_type: "grant.revoked", resource: grant,
          safe_data: { capability: grant.capability, project_id: grant.project_id })
        grant
      end
    end

    def self.scoped_to_parent(parent, capability:)
      raise ActiveRecord::RecordNotFound unless parent&.active? && !parent.guest?
      raise ArgumentError, "Invalid grant capability" unless CAPABILITIES.include?(capability)
      joins(:relationship, :project).where(status: "active", capability: capability)
        .where("abroa_grants.expires_at IS NULL OR abroa_grants.expires_at > ?", Time.current)
        .where(abroa_relationships: {
          parent_user_id: parent.id, parent_family_id: parent.family_id, status: "active"
        })
        .where("abroa_grants.family_id = abroa_relationships.student_family_id")
        .where("abroa_study_projects.family_id = abroa_relationships.student_family_id")
        .where("abroa_study_projects.owner_id = abroa_relationships.student_user_id")
    end

    def self.projects_for_parent(parent, capability:)
      StudyProject.where(id: scoped_to_parent(parent, capability: capability)
        .where(resource_kind: "project", resource_id: nil).select(:project_id))
        .distinct
    end

    def self.allowed?(parent, project, capability, resource_kind: "project", resource_id: nil)
      return false unless parent&.active? && project && CAPABILITIES.include?(capability)
      scope = scoped_to_parent(parent, capability: capability).where(project_id: project.id)
      if resource_kind == "project"
        scope.where(resource_kind: "project", resource_id: nil).exists?
      else
        scope.where(resource_kind: "project", resource_id: nil).or(
          scope.where(resource_kind: resource_kind, resource_id: resource_id)).exists?
      end
    end

    def self.authorized_project!(parent, id, capability:)
      projects_for_parent(parent, capability: capability).find(id)
    end

    def payload
      attributes.slice("id", "relationship_id", "project_id", "capability", "resource_kind", "resource_id", "status", "expires_at",
        "revoked_at", "version", "lock_version", "created_at")
    end

    private
      def student_owned_scope
        return unless relationship && project && actor
        errors.add(:family, :invalid) unless family_id == relationship.student_family_id &&
          family_id == project.family_id && project.owner_id == relationship.student_user_id &&
          actor_id == relationship.student_user_id
        if resource_kind != "project" && project && resource_id
          klass = { "budget_node" => BudgetNode, "fee_plan" => FeePlan, "fund_pool" => FundPool }[resource_kind]
          errors.add(:resource_id, :invalid) unless klass && klass.where(id: resource_id,
            project_id: project_id, family_id: family_id).exists?
        end
      end

      def future_expiry
        errors.add(:expires_at, :invalid) if expires_at <= Time.current
      end
  end
end
