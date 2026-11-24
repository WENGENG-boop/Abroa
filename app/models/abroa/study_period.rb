module Abroa
  class StudyPeriod < ApplicationRecord
    self.table_name = "abroa_study_periods"
    FIELDS = %i[name kind start_on end_on parent_id].freeze
    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :parent, class_name: "Abroa::StudyPeriod", optional: true
    has_many :children, class_name: "Abroa::StudyPeriod", foreign_key: :parent_id
    validates :name, :kind, :start_on, :end_on, presence: true
    validates :kind, inclusion: { in: %w[year term month custom] }
    validate :valid_hierarchy

    def self.create_for!(user, project_id, attributes:, key: nil)
      fields = checked(attributes)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        writer = lambda do
          record = project.periods.create!(fields.merge(family: user.family))
          PlanningAuditEvent.record!(actor: user, event_type: "study_period.created", resource: record)
          record
        end
        key ? OperationRecord.perform!(actor: user, operation: "study_period.create:#{project.id}", key: key, payload: fields, &writer) : writer.call
      end
    end

    def self.change_for!(user, project_id, id, version:, attributes:)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        period = project.periods.lock.find(id)
        raise StudyProject::Conflict, "Period version changed" unless version.is_a?(Integer) && period.lock_version == version
        period.update!(checked(attributes))
        PlanningAuditEvent.record!(actor: user, event_type: "study_period.updated", resource: period)
        period
      end
    end

    def self.remove_for!(user, project_id, id, version:)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        period = project.periods.lock.find(id)
        raise StudyProject::Conflict, "Period version changed" unless version.is_a?(Integer) && period.lock_version == version
        raise StudyProject::Conflict, "Period has children" if period.children.exists?
        period.destroy!
        PlanningAuditEvent.record!(actor: user, event_type: "study_period.removed", resource: period)
        period
      end
    end

    def self.checked(attributes)
      attributes = attributes.symbolize_keys
      raise ArgumentError, "Unknown period field" unless (attributes.keys - FIELDS).empty?
      attributes
    end

    private
      def valid_hierarchy
        unless project && family_id == project.family_id && start_on && end_on
          errors.add(:base, :invalid)
          return
        end
        if end_on < start_on || start_on < project.start_on || (project.end_on && end_on > project.end_on)
          errors.add(:base, "Period is outside project")
        end
        if parent_id
          ancestor = project.periods.find_by(id: parent_id)
          if !ancestor || start_on < ancestor.start_on || end_on > ancestor.end_on
            errors.add(:parent, :invalid)
          end
          seen = Set[id]
          while ancestor
            if seen.include?(ancestor.id)
              errors.add(:parent, "Hierarchy cycle")
              break
            end
            seen.add(ancestor.id)
            ancestor = ancestor.parent
          end
        end
        if persisted? && children.where("start_on < ? OR end_on > ?", start_on, end_on).exists?
          errors.add(:base, "Period excludes children")
        end
      end
  end
end
