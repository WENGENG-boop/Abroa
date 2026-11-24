module Abroa
  # Replays financially significant create requests without creating duplicate facts.
  # Must be called inside the owner's serialized write transaction.
  class OperationRecord < ApplicationRecord
    self.table_name = "abroa_operation_records"
    Conflict = Class.new(StandardError)
    TYPES = %w[Abroa::StudyPeriod Abroa::EntryAllocation Abroa::BudgetNode].freeze

    belongs_to :family
    belongs_to :actor, class_name: "User"

    def self.perform!(actor:, operation:, key:, payload:)
      raise ArgumentError, "Idempotency-Key must contain 1 to 128 bytes" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      raise ArgumentError, "Invalid operation" unless operation.is_a?(String) && operation.bytesize.between?(1, 100)
      key_digest = Digest::SHA256.hexdigest(key)
      request_digest = Digest::SHA256.hexdigest(JSON.generate(payload.deep_stringify_keys.sort.to_h))
      existing = find_by(actor: actor, operation: operation, key_digest: key_digest)
      if existing
        raise Conflict, "Idempotency key reused with different payload" unless existing.request_digest == request_digest
        raise Conflict, "Unknown replay resource" unless TYPES.include?(existing.resource_type)
        model = existing.resource_type.constantize
        return model.where(id: existing.resource_id, family_id: actor.family_id).first || raise(Conflict, "Replayed resource is unavailable")
      end
      resource = yield
      create!(family: actor.family, actor: actor, operation: operation, key_digest: key_digest,
        request_digest: request_digest, resource_type: resource.class.name, resource_id: resource.id)
      resource
    end
  end
end
