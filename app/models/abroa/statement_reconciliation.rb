module Abroa
  # Reconcile confirmed bank statement movements against the existing ledger.
  # This changes only Sure's reconciliation markers, never balances or amounts.
  class StatementReconciliation
    MAX_ENTRIES = 2_000
    MAX_HISTORY = 50
    Conflict = StatementIntake::Conflict

    def self.preview_for!(user, statement_id:)
      with_receipt(user, statement_id) do |receipt, statement, account|
        result, _rows = inspect_ledger(receipt, statement, account)
        result
      end
    end

    def self.confirm_for!(user, statement_id:, digest:)
      unless digest.is_a?(String) && digest.match?(/\A[0-9a-f]{64}\z/)
        raise ArgumentError, "Invalid reconciliation preview digest"
      end
      with_receipt(user, statement_id) do |receipt, statement, account|
        active = receipt.summary["reconciliation"]
        if active
          raise Conflict, "Reconciliation already confirmed" unless active["digest"] == digest
          verify_markers!(active, statement, account)
          next result_for(active, "reconciled")
        end

        history = Array(receipt.summary["reconciliation_history"])
        raise Conflict, "Too many reconciliation revisions" if history.size >= MAX_HISTORY
        preview, rows = inspect_ledger(receipt, statement, account)
        unless preview[:status] == "ready" && preview[:digest] == digest
          raise Conflict, "Statement reconciliation needs a current complete preview"
        end
        timestamp = Time.current
        snapshots = rows.map do |row|
          row.mark_reconciled!(statement: statement, at: timestamp)
          { "entry_id" => row.id, "fingerprint" => SourceAction.fingerprint(row.reload) }
        end
        active = { "digest" => digest, "actor_id" => user.id,
          "confirmed_at" => timestamp.iso8601(6), "entries" => snapshots }
        receipt.update!(summary: receipt.summary.merge("reconciliation" => active))
        result_for(active, "reconciled")
      end
    end

    def self.undo_for!(user, statement_id:)
      with_receipt(user, statement_id) do |receipt, statement, account|
        active = receipt.summary["reconciliation"]
        history = Array(receipt.summary["reconciliation_history"])
        unless active
          last = history.last
          raise Conflict, "No reconciliation to undo" unless last && last["reversed_by_id"] == user.id
          next result_for(last, "reversed")
        end
        raise ActiveRecord::RecordNotFound unless active["actor_id"] == user.id
        rows = verify_markers!(active, statement, account)
        rows.each(&:unmark_reconciled!)
        event = active.merge("reversed_at" => Time.current.iso8601(6), "reversed_by_id" => user.id)
        receipt.update!(summary: receipt.summary.except("reconciliation").merge("reconciliation_history" => history + [event]))
        result_for(event, "reversed")
      end
    end

    class << self
      private
        def with_receipt(user, statement_id)
          StatementIntake.send(:with_statement, user, statement_id) do |family, statement, account|
            receipt = StatementIntake.find_by!(family: family, statement: statement)
            receipt.lock!
            raise ActiveRecord::RecordNotFound unless receipt.account_id == account.id
            raise Conflict, "Reconciliation requires a staged bank statement" if receipt.summary["reversed_at"].present?
            unless receipt.source_kind == "bank_statement" && account.accountable_type == "Depository"
              raise ArgumentError, "Only deposit-account bank statements support this reconciliation"
            end
            yield receipt, statement, account
          end
        end

        def inspect_ledger(receipt, statement, account)
          issues = []
          start_on, end_on = statement.period_start_on, statement.period_end_on
          valid_period = start_on && end_on && start_on <= end_on && end_on <= Date.current &&
            (end_on - start_on).to_i <= 366
          issues << "missing_or_invalid_period" unless valid_period
          issues << "currency_mismatch" unless statement.statement_currency == account.currency
          issues << "invalid_statement_rows" unless receipt.summary["issue_count"] == 0
          issues << "already_reconciled" if receipt.summary["reconciliation"].present?

          ids = receipt.summary["source_ids"]
          unless ids.is_a?(Array) && ids.any? && ids.size <= MAX_ENTRIES
            issues << "missing_or_excess_source_manifest"
            ids = []
          end
          sources = SourceRecord.where(family_id: receipt.family_id, id: ids).order(:id).lock.to_a
          issues << "source_manifest_changed" unless sources.size == ids.size
          source_rows = []
          sources.each do |source|
            unless source.account_id == account.id && source.status.in?(%w[linked posted]) &&
                source.entry_id.present? && source.normalized["provider_status"] == "posted" &&
                source.observations.where(statement: statement, status: "observed").exists? &&
                !source.observations.where(status: "conflict").exists?
              issues << "unresolved_statement_entries"
              next
            end
            source_rows << source
          end

          rows = []
          checks = []
          if valid_period
            rows = account.entries.where(entryable_type: "Transaction", date: start_on..end_on)
              .excluding_pending.excluding_split_parents.order(:id).limit(MAX_ENTRIES + 1).lock.to_a
            raise ArgumentError, "Statement period contains too many entries" if rows.size > MAX_ENTRIES
            Transaction.where(id: rows.map(&:entryable_id)).order(:id).lock.load
            by_id = rows.index_by(&:id)
            sources_match = source_rows.all? do |source|
              row = by_id[source.entry_id]
              row && !row.excluded? && !row.split_child? && !row.statement_reconciled? &&
                row.currency == account.currency && source.currency == row.currency &&
                source.local_date == row.date && source.signed_amount == row.amount
            rescue ArgumentError
              false
            end
            issues << "unmatched_statement_entries" unless sources_match
            matched_ids = source_rows.map(&:entry_id)
            issues << "unmatched_ledger_entries" unless matched_ids.sort == rows.map(&:id).sort
            issues << "existing_reconciliation" if rows.any?(&:statement_reconciled?)
            issues << "unsupported_ledger_movements" if rows.any? { |row| row.excluded? || row.split_child? || row.currency != account.currency }

            balances = account.balances.where(currency: account.currency, date: [start_on, end_on]).order(:date).lock.to_a
            lookup = balances.index_by { |balance| [balance.date, balance.currency] }
            checks = statement.reconciliation_checks(balance_lookup: ->(date, currency) { lookup[[date, currency]] })
            unless checks.size == 3 && checks.all? { |check| check[:difference].zero? }
              issues << "missing_or_mismatched_balances"
            end
            unless statement.opening_balance && statement.closing_balance &&
                statement.closing_balance - statement.opening_balance == -rows.sum(&:amount)
              issues << "movement_total_mismatch"
            end
          end

          issues.uniq!
          digest = Digest::SHA256.hexdigest(JSON.generate([
            receipt.id, receipt.preview_digest, statement.attributes.slice("account_id", "period_start_on",
              "period_end_on", "opening_balance", "closing_balance", "currency", "content_sha256"),
            sources.map { |source| [source.id, source.lock_version, source.entry_id, source.status] },
            rows.map { |row| [row.id, SourceAction.fingerprint(row)] }, checks, issues
          ]))
          [{ status: issues.empty? ? "ready" : "review", digest: digest,
            entry_count: rows.size, issues: issues, balance_checks: checks }, rows]
        end

        def verify_markers!(active, statement, account)
          snapshots = active.fetch("entries")
          rows = account.entries.where(id: snapshots.map { |row| row.fetch("entry_id") }).order(:id).lock.to_a
          unless rows.size == snapshots.size && rows.all?(&:transaction?)
            raise Conflict, "Reconciled entries have changed"
          end
          Transaction.where(id: rows.map(&:entryable_id)).order(:id).lock.load
          rows_by_id = rows.index_by(&:id)
          unless snapshots.all? do |snapshot|
            row = rows_by_id.fetch(snapshot.fetch("entry_id"))
            row.reconciled_by_statement_id == statement.id && row.statement_reconciled? &&
              SourceAction.fingerprint(row) == snapshot.fetch("fingerprint")
          end
            raise Conflict, "Reconciled entries have later changes"
          end
          rows
        end

        def result_for(event, status)
          { status: status, digest: event.fetch("digest"), entry_count: event.fetch("entries").size,
            confirmed_at: event.fetch("confirmed_at"), reversed_at: event["reversed_at"] }
        end
    end
  end
end
