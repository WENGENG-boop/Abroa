module Abroa
  class ProviderCapture
    MAX_LIMIT = 500
    DEFAULT_LIMIT = 100
    SYNC_STATES = %w[pending syncing completed failed stale].freeze

    # Imports provenance from existing provider-identified ledger rows.
    # This does not call a bank, fetch new transactions, or modify entries.
    def self.capture_for!(user, account_id:, limit: DEFAULT_LIMIT, after_id: nil)
      unless limit.is_a?(Integer) && limit.between?(1, MAX_LIMIT) &&
          (after_id.nil? || UuidFormat.valid?(after_id))
        raise ArgumentError, "Invalid capture limit or cursor"
      end
      raise ActiveRecord::RecordNotFound unless user
      user.with_lock do
        raise ActiveRecord::RecordNotFound unless user.active? && !user.guest?
        family = user.family
        family.with_lock do
          account = family.accounts.writable_by(user).find(account_id)
          account.lock!
          raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)

          capture_page!(account, limit: limit, after_id: after_id)
        end
      end
    end

    # Internal sync job entry point; account scope originates from a completed Sync.
    def self.capture_sync_page!(account:, updated_from:, updated_through:, after_id: nil)
      family = account.family
      family.with_lock do
        account.lock!
        next if account.pending_deletion?
        capture_page!(account, limit: DEFAULT_LIMIT, after_id: after_id,
          updated_range: updated_from..updated_through)
      end
    end

    def self.capture_page!(account, limit:, after_id:, updated_range: nil)
      family = account.family
      scope = account.entries.where(entryable_type: "Transaction", parent_entry_id: nil)
        .where.not(external_id: [ nil, "" ]).where.not(source: [ nil, "" ]).where.not(amount: 0)
      scope = scope.where(updated_at: updated_range) if updated_range
      scope = scope.where("entries.id > ?", after_id) if after_id
      entries = scope.order(:id).limit(limit + 1).to_a
      selected = entries.first(limit)
      counts = { scanned_count: selected.size, captured_count: 0, conflict_count: 0, invalid_count: 0 }
      selected.each do |entry|
        begin
          source = SourceRecord.transaction(requires_new: true) { ProviderSource.capture_existing!(entry) }
          counts[source.status.in?(%w[review conflict]) ? :conflict_count : :captured_count] += 1
        rescue SourceRecord::IdentityConflict
          counts[:conflict_count] += 1
        rescue ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
          counts[:invalid_count] += 1
        end
      end
      if counts[:invalid_count].positive? || counts[:conflict_count].positive?
        DebugLogEntry.capture(category: "provider_sync", level: "warn",
          message: "Abroa source capture encountered records requiring review",
          source: name, family: family, account: account, metadata: counts)
      end
      counts.merge(account_id: account.id, next_cursor: entries.size > limit ? selected.last.id : nil,
        evidence_origin: "existing_ledger")
    end
    private_class_method :capture_page!

    def self.diagnostics_for!(user, account_id:)
      raise ActiveRecord::RecordNotFound unless user&.active?
      account = user.family.accounts.accessible_by(user).find(account_id)
      raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).show?
      latest = account.syncs.ordered.first
      status = latest&.status
      status = "unknown" unless SYNC_STATES.include?(status)
      records = SourceRecord.where(family: user.family, account: account)
      {
        account_id: account.id, configured_provider_count: account.account_providers.count,
        live_connection_status: "unverified",
        ledger_sync: { status: status, last_started_at: latest&.syncing_at&.iso8601,
          last_completed_at: account.syncs.completed.ordered.first&.completed_at&.iso8601,
          error_code: status == "failed" ? (latest.data&.dig("abroa_error_code").presence_in(ProviderSyncStatus::CODES) || "failed") : (status == "stale" ? "stale" : nil) },
        source_counts: records.group(:status).count,
        missing_ledger_count: records.where(status: %w[linked posted], entry_id: nil).count
      }
    end
  end
end
