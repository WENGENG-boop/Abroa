module Abroa
  class SourceRecord < ApplicationRecord
    self.table_name = "abroa_source_records"
    IdentityConflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :account, optional: true
    belongs_to :entry, optional: true
    belongs_to :import, optional: true
    belongs_to :statement, class_name: "AccountStatement", optional: true
    has_many :observations, class_name: "Abroa::SourceObservation", dependent: :delete_all, inverse_of: :source_record

    validates :source_kind, inclusion: { in: NormalizedSource::KINDS }
    validates :direction, inclusion: { in: NormalizedSource::DIRECTIONS }
    validates :status, inclusion: { in: %w[received parsed linked posted review ignored error reversed conflict] }
    validates :source_instance_key, :source_row_key, :raw_digest, :local_date, :currency, presence: true
    validates :amount, numericality: { greater_than_or_equal_to: 0 }
    validate :same_tenant

    # Trusted internal boundary for both file adapters and existing provider
    # jobs. It only records evidence, never creates or modifies ledger entries.
    def self.ingest!(family:, record:, account: nil, import: nil, statement: nil)
      raise ArgumentError, "Expected normalized source evidence" unless record.is_a?(NormalizedSource)
      [ account, import, statement ].compact.each do |resource|
        raise ActiveRecord::RecordNotFound unless resource.persisted? && resource.family_id == family.id
      end
      identity = { family_id: family.id, source_kind: record.source_kind, source_instance_key: record.source_instance_key }
      family.with_lock do
        observed = SourceObservation.find_by(**identity, source_row_key: record.source_row_key)
        if observed
          canonical = observed.source_record
          if canonical.external_id != record.external_id || observed.raw_digest != record.raw_digest ||
              observed.normalized != record.payload || (account && canonical.account_id != account.id)
            raise IdentityConflict, "Source row identity has conflicting contents"
          end
          next canonical
        end

        canonical = record.external_id && find_by(**identity, external_id: record.external_id)
        if canonical
          incoming = record.payload
          transition = canonical.send(:status_transition_for, incoming, account)
          conflict = transition == :conflict
          canonical.observations.create!(
            **identity, source_row_key: record.source_row_key, raw_digest: record.raw_digest,
            normalized: incoming, status: conflict ? "conflict" : "observed",
            import: import, statement: statement
          )
          case transition
          when :advance
            status = incoming["provider_status"].in?(%w[closed failed]) ? "ignored" : "parsed"
            canonical.update!(normalized: incoming, status: status)
          when :enrich_reference
            canonical.update!(normalized: incoming)
          when :conflict
            canonical.update!(status: "review") unless canonical.status.in?(%w[reversed conflict])
          end
          next canonical
        end

        canonical = create!(
          **identity, account: account, import: import, statement: statement,
          external_id: record.external_id, source_row_key: record.source_row_key,
          raw_digest: record.raw_digest, local_date: record.local_date, occurred_at: record.occurred_at,
          amount: record.amount, currency: record.currency, direction: record.direction,
          payment_channel: record.payment_channel,
          status: record.provider_status.in?(%w[closed failed]) ? "ignored" : "parsed",
          normalized: record.payload
        )
        canonical.observations.create!(
          **identity, source_row_key: record.source_row_key, raw_digest: record.raw_digest,
          normalized: record.payload, status: "observed", import: import, statement: statement
        )
        canonical
      end
    end

    def self.ingest_for!(user, record:, account_id: nil, import_id: nil, statement_id: nil)
      user.with_lock do
        raise ActiveRecord::RecordNotFound if !user.active? || user.guest?
        family = user.family
        account = account_id && family.accounts.writable_by(user).find(account_id)
        import = import_id && Import.where(family: family).find(import_id)
        statement = statement_id && AccountStatement.where(family: family).find(statement_id)
        if import&.account_id && import.account_id != account&.id
          raise ActiveRecord::RecordNotFound
        end
        if statement&.account_id && statement.account_id != account&.id
          raise ActiveRecord::RecordNotFound
        end
        ingest!(family: family, record: record, account: account, import: import, statement: statement)
      end
    end

    def postable?
      status == "parsed" && account_id.present? && normalized["provider_status"] == "posted" &&
        normalized["transaction_kind"].in?(%w[payment income]) &&
        direction.in?(%w[inflow outflow]) && amount.positive?
    end

    def signed_amount
      case direction
      when "inflow" then -amount
      when "outflow" then amount
      else raise ArgumentError, "Unknown source direction"
      end
    end

    def effective_status
      status.in?(%w[linked posted]) && entry_id.nil? ? "conflict" : status
    end

    # Only an exact provider identity already present in Sure can use this
    # path. Cross-source matching and new posting use separate review logic.
    def link_existing_provider_entry!(ledger_entry)
      with_lock do
        unless source_kind == "bank_provider" && account_id == ledger_entry.account_id &&
            external_id == ledger_entry.external_id && normalized["provider_name"] == ledger_entry.source &&
            ledger_entry.entryable_type == "Transaction" && ledger_entry.parent_entry_id.nil? &&
            !ledger_entry.transaction.pending? && normalized["provider_status"] == "posted" &&
            ledger_entry.date == local_date && ledger_entry.currency == currency && ledger_entry.amount == signed_amount
          raise IdentityConflict, "Existing provider entry does not match source evidence"
        end
        next self if status == "linked" && entry_id == ledger_entry.id
        raise IdentityConflict, "Source requires review" unless status == "parsed" && entry_id.nil?

        update!(entry: ledger_entry, status: "linked")
        self
      end
    end

    private
      # A stable external order may progress from pending to a terminal state.
      # Only a change of status alone is safe to accept. Keep each observation,
      # never downgrade a booked order on a late pending file, and never mutate
      # an already posted ledger entry here. Other changes require review.
      def status_transition_for(incoming, incoming_account)
        return :conflict if incoming_account && account_id != incoming_account.id
        return :same if normalized == incoming
        # Backfill a previously missing structured provider reference only
        # when all other movement facts remain exactly the same.
        if source_kind == "bank_provider" && normalized["reference"].nil? &&
            incoming["reference"].present? && status.in?(%w[parsed linked]) &&
            normalized.except("reference") == incoming.except("reference") &&
            !observations.where(status: "conflict").exists?
          return :enrich_reference
        end
        return :conflict unless normalized.except("provider_status") == incoming.except("provider_status")

        previous = normalized["provider_status"]
        current = incoming["provider_status"]
        if previous == "pending" && current.in?(%w[posted closed failed]) &&
            status == "parsed" && entry_id.nil? && !observations.where(status: "conflict").exists?
          :advance
        elsif previous.in?(%w[posted closed failed]) && current == "pending"
          :same
        else
          :conflict
        end
      end

      def same_tenant
        errors.add(:account, :invalid) if account && account.family_id != family_id
        if entry && (entry.account.family_id != family_id || entry.account_id != account_id)
          errors.add(:entry, :invalid)
        end
        errors.add(:import, :invalid) if import && import.family_id != family_id
        errors.add(:statement, :invalid) if statement && statement.family_id != family_id
      end
  end
end
