module Abroa
  class Relationship < ApplicationRecord
    self.table_name = "abroa_relationships"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :student_user, class_name: "User"
    belongs_to :parent_user, class_name: "User"
    belongs_to :student_family, class_name: "Family"
    belongs_to :parent_family, class_name: "Family"
    has_many :grants, class_name: "Abroa::Grant", dependent: :restrict_with_exception

    validates :status, inclusion: { in: %w[active revoked expired] }
    validate :independent_tenants

    def self.for_actor(user)
      raise ActiveRecord::RecordNotFound unless user&.active?
      where(student_user_id: user.id).or(where(parent_user_id: user.id))
    end

    def self.revoke_for!(actor, id, version:)
      StudyProject.with_actor(actor) do
        relation = for_actor(actor).lock.find(id)
        raise Conflict, "Relationship version changed" unless version.is_a?(Integer) && relation.lock_version == version
        raise Conflict, "Relationship is not active" unless relation.status == "active"
        relation.update!(status: "revoked", revoked_at: Time.current, version: relation.version + 1)
        relation.grants.where(status: "active").order(:id).lock.each do |grant|
          grant.update!(status: "revoked", revoked_at: Time.current, version: grant.version + 1)
        end
        PlanningAuditEvent.record!(actor: actor, event_type: "relationship.revoked", resource: relation)
        relation
      end
    end

    def active_for?(user)
      status == "active" && user&.active? &&
        (user.id == student_user_id || user.id == parent_user_id)
    end

    def payload
      attributes.slice("id", "student_user_id", "parent_user_id", "status",
        "accepted_at", "revoked_at", "version", "lock_version")
    end

    private
      def independent_tenants
        return unless student_user && parent_user
        errors.add(:student_user, :invalid) if student_user_id == parent_user_id ||
          student_user.family_id == parent_user.family_id
        errors.add(:student_family, :invalid) unless student_family_id == student_user.family_id &&
          family_id == student_family_id
        errors.add(:parent_family, :invalid) unless parent_family_id == parent_user.family_id
      end
  end
end
