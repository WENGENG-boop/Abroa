module Abroa
  class PlanningDraft < ApplicationRecord
    self.table_name = "abroa_planning_drafts"
    Conflict = Class.new(StandardError)
    FIELDS = %i[title kind payload].freeze
    BUDGET_FIELDS = %w[name currency start_on end_on limit_amount parent_id period_id category_id
      rollover_enabled warning_threshold].freeze
    PROJECT_FIELDS = %w[name country origin_country city school timezone start_on end_on currency].freeze
    FUNDING_FIELDS = %w[name amount currency frequency scheduled_on ends_on source_account_id fund_pool_id].freeze

    belongs_to :family
    belongs_to :parent_user, class_name: "User"
    validates :title, length: { minimum: 1, maximum: 200 }
    validates :kind, inclusion: { in: %w[budget study_project] }
    validates :status, inclusion: { in: %w[draft submitted accepted rejected cancelled] }
    validate :validate_tenancy_and_payload

    def self.for_user(user)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      where(parent_user_id: user.id, family_id: user.family_id)
    end

    def self.find_for!(user, id)
      for_user(user).find(id)
    end

    def self.create_for!(user, attributes:, key:)
      fields = checked(attributes)
      raise ArgumentError, "Idempotency-Key required" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      digest = Digest::SHA256.hexdigest(key)
      request = Digest::SHA256.hexdigest(JSON.generate(fields.deep_stringify_keys.sort.to_h))
      StudyProject.with_actor(user) do
        raise ActiveRecord::RecordNotFound unless Profile.for_user(user).parent_enabled?
        old = for_user(user).find_by(creation_key_digest: digest)
        if old
          raise Conflict, "Draft request changed" unless old.creation_request_digest == request
          next old
        end
        record = create!(fields.merge(family: user.family, parent_user: user,
          creation_key_digest: digest, creation_request_digest: request))
        PlanningAuditEvent.record!(actor: user, event_type: "parent_draft.created", resource: record)
        record
      end
    end

    def self.change_for!(user, id, version:, attributes:)
      fields = checked(attributes)
      StudyProject.with_actor(user) do
        record = for_user(user).lock.find(id)
        raise Conflict, "Draft changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Draft not editable" unless record.status == "draft"
        record.update!(fields)
        PlanningAuditEvent.record!(actor: user, event_type: "parent_draft.updated", resource: record)
        record
      end
    end

    def self.cancel_for!(user, id, version:)
      StudyProject.with_actor(user) do
        record = for_user(user).lock.find(id)
        raise Conflict, "Draft changed" unless version.is_a?(Integer) && record.lock_version == version
        raise Conflict, "Draft not editable" unless record.status == "draft"
        record.update!(status: "cancelled")
        PlanningAuditEvent.record!(actor: user, event_type: "parent_draft.cancelled", resource: record)
        record
      end
    end

    def self.checked(fields)
      value = fields.to_h.symbolize_keys
      raise ArgumentError, "Unknown planning field" unless (value.keys - FIELDS).empty?
      value
    end

    def payload_data
      attributes.slice("id", "title", "kind", "payload", "status", "lock_version", "created_at")
    end

    private
      def validate_tenancy_and_payload
        errors.add(:family, :invalid) unless parent_user && parent_user.family_id == family_id &&
          Profile.for_user(parent_user).parent_enabled?
        unless payload.is_a?(Hash) && payload.size.between?(1, 20) &&
            payload.to_json.bytesize <= 8_192 &&
            (payload.keys - { "budget" => BUDGET_FIELDS, "study_project" => PROJECT_FIELDS,
              "funding" => FUNDING_FIELDS }.fetch(kind, [])).empty?
          errors.add(:payload, :invalid)
        end
      end
  end
end
