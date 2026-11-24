module Abroa
  class SourceAction < ApplicationRecord
    self.table_name = "abroa_source_actions"

    belongs_to :family
    belongs_to :source_record
    belongs_to :source_review
    belongs_to :actor, class_name: "User", optional: true
    belongs_to :entry, optional: true
    belongs_to :reversed_by, class_name: "User", optional: true

    validates :operation, inclusion: { in: %w[create link ignore dismiss] }
    validates :operation_key, :request_digest, presence: true
    validate :same_tenant

    def payload
      { id: id, source_record_id: source_record_id, review_id: source_review_id,
        operation: operation, entry_id: entry_id, reversed_at: reversed_at&.iso8601(6) }
    end

    # Snapshot the actual ledger row and its transaction, not just amount/date.
    # Tag/attachment changes are independent of those rows.
    def self.fingerprint(entry)
      transaction = entry.transaction
      Digest::SHA256.hexdigest(JSON.generate([
        entry.attributes.sort.to_h, transaction.attributes.sort.to_h,
        transaction.tag_ids.sort, transaction.attachments.attachments.pluck(:id).sort
      ]))
    end

    # A verified reconciliation/undo pair is an explicitly audited state
    # transition. Follow only the exact full fingerprints recorded before and
    # after it; never ignore timestamps or user edits in a rollback check.
    def self.rollback_fingerprint_matches?(entry, action)
      expected = action.after_data["fingerprint"]
      current = fingerprint(entry)
      return true if expected == current
      receipts = StatementIntake.where(family_id: action.family_id, account_id: entry.account_id)
        .where("summary -> 'reconciliation_history' @> ?::jsonb",
          [{ "entries" => [{ "entry_id" => entry.id }] }].to_json).limit(51).to_a
      return false if receipts.size > 50
      events = receipts.flat_map { |receipt| Array(receipt.summary["reconciliation_history"]) }
      events.sort_by { |event| event["reversed_at"].to_s }.each do |event|
        next unless event["reversed_at"].present?
        snapshot = Array(event["entries"]).find { |row| row["entry_id"] == entry.id }
        next unless snapshot && snapshot["before_fingerprint"] == expected &&
          snapshot["restored_fingerprint"].present?
        expected = snapshot["restored_fingerprint"]
      end
      expected == current
    end

    private
      def same_tenant
        errors.add(:source_record, :invalid) unless source_record && source_record.family_id == family_id
        unless source_review && source_review.family_id == family_id && source_review.source_record_id == source_record_id
          errors.add(:source_review, :invalid)
        end
        errors.add(:actor, :invalid) if actor && actor.family_id != family_id
        if entry && (entry.account.family_id != family_id || entry.account_id != source_record&.account_id)
          errors.add(:entry, :invalid)
        end
      end
  end
end
