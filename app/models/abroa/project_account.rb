module Abroa
  class ProjectAccount < ApplicationRecord
    self.table_name = "abroa_project_accounts"
    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :account
    validate :same_family

    def self.attach_for!(user, project_id, account_id)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        account = user.family.accounts.accessible_by(user).find(account_id)
        link = project.project_accounts.find_or_create_by!(family: user.family, account: account)
        if link.previously_new_record?
          PlanningAuditEvent.record!(actor: user, event_type: "project_account.attached", resource: link)
        end
        link
      end
    end

    def self.detach_for!(user, project_id, account_id)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        link = project.project_accounts.find_by!(account_id: account_id)
        if project.allocations.joins(:entry).where(entries: { account_id: account_id }).exists?
          raise StudyProject::Conflict, "Account has project allocations"
        end
        link.destroy!
        PlanningAuditEvent.record!(actor: user, event_type: "project_account.detached", resource: link)
        link
      end
    end

    private
      def same_family
        errors.add(:base, :invalid) unless project&.family_id == family_id && account&.family_id == family_id
      end
  end
end
