module Abroa
  # Apply only an unambiguous, explicitly configured category rule.
  # Never execute arbitrary rule actions, call AI, or override user categories.
  class ImportClassification
    MAX_RULES = 100

    def self.apply_for!(user, entry)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      user.with_lock do
        family = user.family
        family.with_lock do
          account = family.accounts.writable_by(user).find(entry.account_id)
          account.lock!
          raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)
          entry = account.entries.find(entry.id)
          entry.lock!
          next "not_eligible" unless entry.transaction? && !entry.excluded? &&
            !entry.split_parent? && !entry.split_child? && !entry.scheduled?
          txn = entry.transaction
          txn.lock!
          next "not_eligible" unless txn.standard? && !txn.pending?
          next "locked" if txn.locked?(:category_id)
          next "already_classified" if txn.category_id.present?
          next "locked" if entry.user_modified?
          next "manual" if Profile.for_user(user).import_automation == "manual"

          rules = family.rules.applied_immediately.where(resource_type: "transaction")
            .where(id: Rule::Action.where(action_type: "set_transaction_category").select(:rule_id))
            .ordered.limit(MAX_RULES + 1).includes(:actions, :conditions).to_a
          next "review" if rules.size > MAX_RULES
          matches = rules.filter_map do |rule|
            next unless rule.actions.size == 1 && rule.conditions.any?
            next unless rule.matches_transaction?(txn)
            action = rule.actions.first
            next unless action.action_type == "set_transaction_category"
            action.value
          end.uniq
          next "review" unless matches.one?
          category = family.categories.find_by(id: matches.first)
          next "review" unless category
          changed = txn.enrich_attribute(:category_id, category.id, source: "rule",
            metadata: { "abroa_import" => true }, ignore_locks: false)
          changed ? "classified" : "review"
        end
      end
    end
  end
end
