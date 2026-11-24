module Abroa
  class SourceObservation < ApplicationRecord
    self.table_name = "abroa_source_observations"
    belongs_to :family
    belongs_to :source_record, class_name: "Abroa::SourceRecord"
    belongs_to :import, optional: true
    belongs_to :statement, class_name: "AccountStatement", optional: true

    validates :status, inclusion: { in: %w[observed conflict] }
    validates :source_row_key, :source_instance_key, :source_kind, :raw_digest, presence: true
    validate :consistent_provenance

    private
      def consistent_provenance
        unless source_record && source_record.family_id == family_id &&
            source_record.source_kind == source_kind && source_record.source_instance_key == source_instance_key
          errors.add(:source_record, :invalid)
        end
        errors.add(:import, :invalid) if import && import.family_id != family_id
        errors.add(:statement, :invalid) if statement && statement.family_id != family_id
      end
  end
end
