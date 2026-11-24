module Abroa
  class ProviderSource
    # Read-through adapter for records already synced by the original Sure
    # provider pipeline. The existing ledger remains the authoritative fact.
    def self.capture_existing!(entry)
      family = entry.account.family
      family.with_lock do
        entry.lock!
        unless entry.entryable_type == "Transaction" && entry.external_id.present? &&
            entry.source.present? && entry.parent_entry_id.nil? && !entry.amount.zero?
          raise ArgumentError, "Entry is not an externally identified transaction"
        end
        transaction = entry.transaction
        kind = if transaction.kind.in?(%w[funds_movement cc_payment loan_payment investment_contribution])
          "transfer"
        elsif entry.amount.positive?
          "payment"
        else
          "unknown"
        end
        evidence = {
          external_id: entry.external_id, provider_name: entry.source,
          local_date: entry.date, amount: entry.amount.abs, currency: entry.currency,
          direction: entry.amount.negative? ? "inflow" : "outflow",
          provider_status: transaction.pending? ? "pending" : "posted",
          transaction_kind: kind, description: entry.name.to_s.truncate(256)
        }
        digest = Digest::SHA256.hexdigest(evidence.to_json)
        instance = Digest::SHA256.hexdigest([ entry.account_id, entry.source ].to_json)
        record = NormalizedSource.build(
          **evidence, source_kind: "bank_provider", source_instance_key: instance,
          source_row_key: "provider:#{digest}", raw_digest: digest
        )
        source = SourceRecord.ingest!(family: family, record: record, account: entry.account)
        if record.provider_status == "posted" && source.status.in?(%w[parsed linked])
          source.link_existing_provider_entry!(entry)
        else
          source
        end
      end
    end
  end
end
