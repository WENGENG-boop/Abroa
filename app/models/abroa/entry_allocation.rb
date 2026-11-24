module Abroa
  class EntryAllocation < ApplicationRecord
    self.table_name = "abroa_entry_allocations"
    belongs_to :family
    belongs_to :project, class_name: "Abroa::StudyProject"
    belongs_to :entry, optional: true
    belongs_to :category, optional: true
    scope :visible_to, ->(user) do
      joins(:entry).where(entries: { account_id: user.family.accounts.accessible_by(user).select(:id) })
    end

    validates :amount, numericality: { greater_than: 0 }
    validate :valid_provenance, on: :create

    def self.allocate_for!(user, project_id, entry_id:, amount:, currency: nil, category_id: nil, key: nil)
      amount = Decimal.money!(amount, positive: true)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        writer = lambda do
          entry = locked_entry!(user, entry_id)
          validate_entry!(entry)
          raise ArgumentError, "Currency differs from entry" if currency && Decimal.currency!(currency) != entry.currency
          category = category_id && user.family.categories.find(category_id)
          remaining = remaining_amount(entry)
          raise ArgumentError, "Allocation exceeds available amount or requires reconciliation" if !remaining || amount > remaining
          record = project.allocations.create!(family: user.family, entry: entry, entry_key: entry.id, amount: amount,
            currency: entry.currency, entry_date: entry.date, direction: entry.amount.positive? ? "expense" : "income", category: category)
          PlanningAuditEvent.record!(actor: user, event_type: "entry_allocation.created", resource: record,
            safe_data: { entry_id: entry.id, amount: amount.to_s("F"), currency: entry.currency })
          record
        end
        key ? OperationRecord.perform!(actor: user, operation: "entry_allocation.create:#{project.id}", key: key,
          payload: { entry_id: entry_id, amount: amount.to_s("F"), currency: currency, category_id: category_id }, &writer) : writer.call
      end
    end

    def self.change_for!(user, project_id, id, version:, amount: nil, category_id: :unchanged)
      amount = Decimal.money!(amount, positive: true) if amount
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        allocation = project.allocations.find(id)
        entry = locked_entry!(user, allocation.entry_id)
        allocation.lock!
        raise StudyProject::Conflict, "Allocation version changed" unless version.is_a?(Integer) && allocation.lock_version == version
        new_amount = amount || allocation.amount
        remaining = remaining_amount(entry)
        raise ArgumentError, "Allocation exceeds available amount or requires reconciliation" if !remaining || new_amount > remaining + allocation.amount
        category = category_id == :unchanged ? allocation.category : (category_id && user.family.categories.find(category_id))
        old_amount = allocation.amount
        if where(project_id: project.id, entry_key: entry.id, category_id: category&.id).where.not(id: allocation.id).exists?
          raise StudyProject::Conflict, "Allocation category conflicts with existing split"
        end
        allocation.update!(amount: new_amount, category: category)
        PlanningAuditEvent.record!(actor: user, event_type: "entry_allocation.updated", resource: allocation,
          safe_data: { old_amount: old_amount.to_s("F"), amount: new_amount.to_s("F"), category_id: category&.id })
        allocation
      end
    end

    def self.remove_for!(user, project_id, id, version:)
      StudyProject.with_actor(user) do
        project = StudyProject.find_for!(user, project_id)
        project.ensure_writable!
        allocation = project.allocations.find(id)
        locked_entry!(user, allocation.entry_id)
        allocation.lock!
        raise StudyProject::Conflict, "Allocation version changed" unless version.is_a?(Integer) && allocation.lock_version == version
        allocation.destroy!
        PlanningAuditEvent.record!(actor: user, event_type: "entry_allocation.removed", resource: allocation,
          safe_data: { entry_id: allocation.entry_key, amount: allocation.amount.to_s("F") })
        allocation
      end
    end

    def payload
      { id: id, project_id: project_id, entry_id: entry_id, category_id: category_id,
        amount: amount.to_s("F"), currency: currency, entry_date: entry_date.iso8601,
        direction: direction, lock_version: lock_version, consistent: consistent? }
    end

    def self.remaining_for!(user, entry_id)
      StudyProject.with_actor(user) { remaining_amount(locked_entry!(user, entry_id)) }
    end

    def self.locked_entry!(user, id)
      found = Entry.where(account_id: user.family.accounts.writable_by(user).select(:id)).find(id)
      account = user.family.accounts.lock.find(found.account_id)
      raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)
      entry = account.entries.lock.find(id)
      Transaction.where(id: entry.entryable_id).lock.load if entry.transaction?
      entry
    end

    def self.validate_entry!(entry)
      unless entry && entry.transaction? && entry.transaction.kind == "standard" && !entry.transaction.pending? &&
          !entry.excluded? && !entry.split_parent? && !entry.scheduled? && !entry.amount.zero?
        raise ArgumentError, "Expected an eligible confirmed ledger entry"
      end
    end

    def self.remaining_amount(entry)
      validate_entry!(entry)
      allocations = where(entry_id: entry.id)
      return nil unless allocations.all?(&:consistent?)
      entry.amount.abs - allocations.sum(:amount)
    end

    def consistent?
      self.class.validate_entry!(entry)
      entry.id == entry_key && entry.account.family_id == family_id && project.family_id == family_id &&
        entry.currency == currency && entry.date == entry_date &&
        (entry.amount.positive? ? "expense" : "income") == direction &&
        self.class.where(entry_id: entry_id).sum(:amount) <= entry.amount.abs
    rescue ArgumentError
      false
    end

    private
      def valid_provenance
        unless entry && project && entry.account.family_id == family_id && project.family_id == family_id &&
            entry.id == entry_key && (!category || category.family_id == family_id)
          errors.add(:base, :invalid)
        end
      end
  end
end
