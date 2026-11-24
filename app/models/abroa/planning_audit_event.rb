module Abroa
  # Append-only, non-sensitive provenance for project planning changes.
  class PlanningAuditEvent < ApplicationRecord
    self.table_name = "abroa_planning_audit_events"
    belongs_to :family
    belongs_to :actor, class_name: "User", optional: true

    def self.record!(actor:, event_type:, resource:, safe_data: {})
      create!(family: actor.family, actor: actor, event_type: event_type,
        resource_type: resource.class.name, resource_id: resource.id,
        safe_data: safe_data, occurred_at: Time.current)
    end

    def readonly?
      persisted? || super
    end
  end
end
