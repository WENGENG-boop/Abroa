module Abroa
  class BudgetVersion < ApplicationRecord
    self.table_name = "abroa_budget_versions"
    belongs_to :family
    belongs_to :budget_node, class_name: "Abroa::BudgetNode"
    belongs_to :actor, class_name: "User"

    def readonly?
      persisted? || super
    end
  end
end
