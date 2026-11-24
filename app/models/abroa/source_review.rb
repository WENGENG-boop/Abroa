module Abroa
  class SourceReview < ApplicationRecord
    self.table_name = "abroa_source_reviews"
    Conflict = Class.new(StandardError)

    belongs_to :family
    belongs_to :source_record
    belongs_to :resolved_by, class_name: "User", optional: true
    has_one :source_action, class_name: "Abroa::SourceAction"

    validates :status, inclusion: { in: %w[pending resolved dismissed] }
    validates :reason_code, presence: true

    def self.open_for!(user, source_id)
      with_actor(user) do |family|
        source, _account = lock_source!(user, family, source_id)
        raise Conflict, "Source already has a final resolution" unless source.status.in?(%w[parsed review])
        raise Conflict, "Source already has a ledger entry" if source.entry_id.present?
        existing = find_by(source_record: source, review_type: "source_resolution", status: "pending")
        decision = SourceMatcher.call(user: user, source: source)
        if existing
          if existing.evidence["source_version"] != source.lock_version
            existing.update!(reason_code: decision.reason, candidate_ids: decision.candidate_ids,
              evidence: existing.evidence.merge("source_version" => source.lock_version, "proposed_action" => decision.action))
          end
          next existing
        end
        create!(family: family, source_record: source, reason_code: decision.reason,
          candidate_ids: decision.candidate_ids,
          evidence: { "source_version" => source.lock_version, "proposed_action" => decision.action })
      end
    end

    # Reattribute an unresolved personal statement row without touching the
    # ledger or rewriting original evidence. Both account scopes are checked.
    def self.assign_account_for!(user, review_id:, account_id:, funding_kind:, expected_version:)
      unless expected_version.is_a?(Integer) && expected_version >= 0 &&
          %w[wallet bank_account].include?(funding_kind)
        raise ArgumentError, "Invalid funding assignment or version"
      end
      with_actor(user) do |family|
        review = where(family: family).find(review_id)
        source, current = lock_source!(user, family, review.source_record_id)
        review.lock!
        unless review.status == "pending" && review.lock_version == expected_version &&
            review.evidence["source_version"] == source.lock_version &&
            source.status.in?(%w[parsed review]) && source.entry_id.nil? &&
            !SourceAction.where(source_record: source).exists?
          raise Conflict, "Source or review changed"
        end
        statement = source.statement
        unless SourceMatcher::PAYMENT_KINDS.include?(source.source_kind) && statement &&
            statement.manageable_by?(user) && statement.account
          raise ArgumentError, "Expected a personal payment statement"
        end
        target = family.accounts.writable_by(user).find(account_id)
        target.lock!
        unless target.owner_id == statement.account.owner_id &&
            current.owner_id == statement.account.owner_id && AccountPolicy.new(user, target).permits?(:write)
          raise ActiveRecord::RecordNotFound
        end
        original_kind = source.normalized["funding_kind"]
        if original_kind != "unknown" && original_kind != funding_kind
          raise ArgumentError, "Funding classification contradicts source evidence"
        end
        validate_funding_account!(source, target, funding_kind)
        history = Array(review.evidence["funding_assignments"])
        raise Conflict, "Too many funding assignments" if history.size >= 50
        assignment = { "from_account_id" => current.id, "to_account_id" => target.id,
          "funding_kind" => funding_kind, "actor_id" => user.id, "confirmed_at" => Time.current.iso8601(6) }
        source.update!(account: target) if source.account_id != target.id
        decision = SourceMatcher.call(user: user, source: source)
        review.update!(reason_code: decision.reason, candidate_ids: decision.candidate_ids,
          evidence: review.evidence.merge("source_version" => source.lock_version,
            "proposed_action" => decision.action, "funding_assignment" => assignment,
            "funding_assignments" => history + [assignment]))
        review
      end
    end

    # Invoked only while publishing a user-confirmed statement. A savepoint
    # ensures a failed automatic link leaves the original review available.
    def self.try_auto_link_for!(user, review_id:)
      transaction(requires_new: true) do
        with_actor(user) do |family|
          review = where(family: family).find(review_id)
          source, _account = lock_source!(user, family, review.source_record_id)
          review.lock!
          next if Profile.for_user(user).import_automation == "manual"
          next unless source.status == "parsed" && review.status == "pending"
          decision = SourceMatcher.call(user: user, source: source)
          next unless decision.action == "link"
          resolve_for!(user, review_id: review.id, resolution: "link",
            expected_version: review.lock_version, key: "abroa-auto-link-#{review.id}",
            target_entry_id: decision.entry_id, automatic: true)
        end
      end
    rescue Conflict, ArgumentError, ActiveRecord::RecordInvalid, ActiveRecord::RecordNotFound
      nil
    end

    def self.resolve_for!(user, review_id:, resolution:, expected_version:, key:, target_entry_id: nil, movement_kind: nil, automatic: false)
      raise ArgumentError, "Unknown review resolution" unless %w[create link ignore dismiss].include?(resolution)
      raise ArgumentError, "Invalid expected_version" unless expected_version.is_a?(Integer) && expected_version >= 0
      raise ArgumentError, "Invalid Idempotency-Key" unless key.is_a?(String) && key.present? && key.bytesize <= 128
      if (resolution == "link") != target_entry_id.present?
        raise ArgumentError, "A target entry is required only for linking"
      end
      if movement_kind && (!movement_kind.in?(%w[payment income refund]) || !resolution.in?(%w[create link]))
        raise ArgumentError, "Movement classification only applies to financial resolutions"
      end
      if automatic && resolution != "link"
        raise ArgumentError, "Automatic resolution can only link existing entries"
      end
      operation_key = Digest::SHA256.hexdigest("#{user.id}:#{key}")
      request_data = [ review_id, resolution, expected_version, target_entry_id, movement_kind ]
      request_data << "automatic" if automatic
      request_digest = Digest::SHA256.hexdigest(JSON.generate(request_data))

      with_actor(user) do |family|
        review = where(family: family).find(review_id)
        source, account = lock_source!(user, family, review.source_record_id)
        review.lock!
        existing = SourceAction.find_by(family: family, operation_key: operation_key)
        if existing
          unless existing.source_review_id == review.id && existing.request_digest == request_digest && !existing.reversed_at?
            raise Conflict, "Idempotency key already used or reversed"
          end
          next existing
        end

        unless review.status == "pending" && review.lock_version == expected_version &&
            review.evidence["source_version"] == source.lock_version &&
            source.status.in?(%w[parsed review]) && source.entry_id.nil?
          raise Conflict, "Source or review changed"
        end
        before = { "status" => source.status, "source_version" => source.lock_version }
        entry = nil
        channel_added = false
        resolved_kind = nil
        classification_status = nil
        case resolution
        when "create", "link"
          funding_kind = review.effective_funding_kind
          resolved_kind = validate_financial_source!(source, account, movement_kind, funding_kind)
          if resolution == "create"
            validate_creation!(source, account, funding_kind)
            entry = account.entries.create!(entryable: Transaction.new(kind: "standard",
              extra: source.payment_channel.present? ? { "abroa" => { "payment_channel" => source.payment_channel } } : {}),
              amount: source.signed_amount, currency: source.currency, date: source.local_date,
              name: source.normalized.fetch("description"), import_locked: true,
              idempotency_key: "abroa-source-#{source.id}")
            classification_status = ImportClassification.apply_for!(user, entry)
          else
            entry = account.entries.find(target_entry_id)
            entry.lock!
            transaction = entry.transaction if entry.transaction?
            transaction&.lock!
            validate_link!(source, entry)
            if SourceMatcher::PAYMENT_KINDS.include?(source.source_kind) &&
                SourceRecord.where(entry: entry, source_kind: SourceMatcher::PAYMENT_KINDS)
                  .where.not(id: source.id).exists?
              raise Conflict, "Ledger movement already belongs to another payment order"
            end
            if automatic
              decision = SourceMatcher.call(user: user, source: source)
              unless source.status == "parsed" && decision.action == "link" && decision.entry_id == entry.id
                raise Conflict, "Automatic match is no longer unique"
              end
            end
            if source.payment_channel.present?
              extra = transaction.extra.deep_dup
              abroa = extra["abroa"] || {}
              raise Conflict, "Payment channel metadata conflicts" unless abroa.is_a?(Hash)
              existing_channel = abroa["payment_channel"]
              if existing_channel && existing_channel != source.payment_channel
                raise Conflict, "Existing payment channel differs"
              end
              if existing_channel.nil?
                raise Conflict, "Payment metadata is user locked" if transaction.locked?(:extra)
                before["abroa_namespace_present"] = extra.key?("abroa")
                transaction.update!(extra: extra.merge("abroa" => abroa.merge("payment_channel" => source.payment_channel)))
                channel_added = true
              end
            end
          end
          source.update!(entry: entry, status: resolution == "create" ? "posted" : "linked")
        when "ignore", "dismiss"
          source.update!(status: resolution == "ignore" ? "ignored" : "review")
        end

        review.update!(status: resolution == "dismiss" ? "dismissed" : "resolved", resolved_by: user, resolved_at: Time.current)
        after = { "status" => source.status, "source_version" => source.lock_version,
          "entry_id" => entry&.id, "channel_added" => channel_added, "movement_kind" => resolved_kind,
          "fingerprint" => entry && SourceAction.fingerprint(entry.reload) }
        after["automatic"] = true if automatic
        after["classification_status"] = classification_status if classification_status
        action = SourceAction.create!(family: family, source_record: source, source_review: review,
          actor: user, entry: entry, operation: resolution, operation_key: operation_key,
          request_digest: request_digest, before_data: before, after_data: after)
        if resolution == "create"
          ActiveRecord.after_all_transactions_commit { entry.sync_account_later }
        end
        action
      end
    end

    def self.reverse_for!(user, action_id:)
      with_actor(user) do |family|
        action = SourceAction.where(family: family).find(action_id)
        source, _account = lock_source!(user, family, action.source_record_id)
        action.lock!
        raise ActiveRecord::RecordNotFound unless action.actor_id == user.id
        next action if action.reversed_at?
        unless
            source.lock_version == action.after_data["source_version"] &&
            source.status == action.after_data["status"] &&
            source.entry_id == action.after_data["entry_id"]
          raise Conflict, "Source has changed since resolution"
        end

        entry = action.entry
        if action.operation.in?(%w[create link])
          raise Conflict, "Ledger entry no longer exists" unless entry
          entry.lock!
          entry.transaction.lock!
          if entry.statement_reconciled? && StatementIntake.where(family: family)
              .where("summary -> 'reconciliation' -> 'entries' @> ?::jsonb", [{entry_id: entry.id}].to_json).exists?
            raise Conflict, "Undo statement reconciliation first"
          end
          if action.operation == "create"
            validate_reversible_entry!(source, action, entry)
            source.update!(entry: nil, status: "reversed")
            entry.destroy!
            ActiveRecord.after_all_transactions_commit { entry.sync_account_later }
          else
            if action.after_data["channel_added"]
              if SourceRecord.where(entry: entry).where.not(id: source.id).where(payment_channel: source.payment_channel).exists? ||
                  !SourceAction.rollback_fingerprint_matches?(entry, action)
                raise Conflict, "Payment metadata has later dependencies"
              end
              extra = entry.transaction.extra.deep_dup
              namespace = extra.fetch("abroa").except("payment_channel")
              if namespace.empty? && !action.before_data["abroa_namespace_present"]
                extra.delete("abroa")
              else
                extra["abroa"] = namespace
              end
              entry.transaction.update!(extra: extra)
            end
            source.update!(entry: nil, status: "reversed")
          end
        else
          source.update!(status: "reversed")
        end
        action.update!(reversed_at: Time.current, reversed_by: user)
        action
      end
    end

    def effective_funding_kind
      kind = source_record.normalized["funding_kind"]
      assignment = evidence["funding_assignment"]
      if kind == "unknown" && assignment.is_a?(Hash) &&
          assignment["to_account_id"] == source_record.account_id
        assignment["funding_kind"]
      else
        kind
      end
    end

    def payload
      { id: id, source_record_id: source_record_id, reason_code: reason_code,
        candidate_ids: candidate_ids, status: status, lock_version: lock_version,
        proposed_action: evidence["proposed_action"], account_id: source_record.account_id,
        funding_kind: effective_funding_kind }
    end

    class << self
      private
        def with_actor(user)
          raise ActiveRecord::RecordNotFound unless user
          user.with_lock do
            raise ActiveRecord::RecordNotFound unless user.active? && !user.guest?
            family = user.family
            family.with_lock { yield family }
          end
        end

        def lock_source!(user, family, source_id)
          source = SourceRecord.where(family: family).find(source_id)
          # Unassigned evidence currently has no individual owner. Do not expose
          # or mutate it through a family-wide review endpoint.
          raise ActiveRecord::RecordNotFound unless source.account_id
          account = family.accounts.writable_by(user).find(source.account_id)
          account.lock!
          source.lock!
          unless source.account_id == account.id && AccountPolicy.new(user, account).permits?(:write)
            raise ActiveRecord::RecordNotFound
          end
          if source.statement && source.statement.account_id != account.id &&
              !source.statement.manageable_by?(user)
            raise ActiveRecord::RecordNotFound
          end
          [ source, account ]
        end

        def validate_financial_source!(source, account, movement_kind, funding_kind)
          source_kind = source.normalized["transaction_kind"]
          # Preserve raw evidence. Only the user-confirmed audit action records
          # a classification for an otherwise unknown posted movement.
          kind = source_kind == "unknown" ? movement_kind : source_kind
          if movement_kind && source_kind != "unknown" && movement_kind != source_kind
            raise ArgumentError, "Classification contradicts source evidence"
          end
          expected_direction = { "payment" => "outflow", "income" => "inflow", "refund" => "inflow" }[kind]
          unless source.normalized["provider_status"] == "posted" &&
              expected_direction && source.direction == expected_direction && source.amount.positive? &&
              source.local_date <= Date.current && source.currency == account.currency &&
              !source.observations.where(status: "conflict").exists?
            raise ArgumentError, "Source is not a confirmed regular account movement"
          end
          if SourceMatcher::PAYMENT_KINDS.include?(source.source_kind)
            validate_funding_account!(source, account, funding_kind)
          elsif funding_kind == "wallet"
            validate_funding_account!(source, account, funding_kind)
          end
          kind
        end

        def validate_funding_account!(source, account, funding_kind)
          raise ArgumentError, "Funding currency differs" unless account.currency == source.currency
          profile = AccountProfile.find_by(account: account, family_id: source.family_id)
          case funding_kind
          when "wallet"
            unless profile&.wallet_kind == source.payment_channel && account.accountable_type == "Depository"
              raise ArgumentError, "A wallet-funded payment requires the matching wallet account"
            end
          when "bank_account"
            unless profile&.wallet_kind.nil? && account.accountable_type.in?(%w[Depository CreditCard])
              raise ArgumentError, "A bank-funded payment requires a bank account"
            end
          else
            raise ArgumentError, "Confirm the actual funding account before posting"
          end
        end

        def validate_creation!(source, account, funding_kind)
          if source.source_kind == "bank_provider" ||
              (SourceMatcher::PAYMENT_KINDS.include?(source.source_kind) &&
                funding_kind != "wallet")
            raise ArgumentError, "Bank-funded or unidentified payment requires independent ledger evidence"
          end
          unless account.accountable_type.in?(%w[Depository CreditCard OtherAsset OtherLiability])
            raise ArgumentError, "Unsupported account for a regular imported transaction"
          end
        end

        def validate_link!(source, entry)
          unless entry.transaction? && !entry.transaction.pending? && entry.transaction.kind == "standard" &&
              !entry.excluded? && !entry.split_child? && !entry.split_parent? &&
              entry.amount == source.signed_amount && entry.currency == source.currency &&
              (entry.date - source.local_date).abs <= SourceMatcher::DATE_WINDOW
            raise ArgumentError, "Target entry does not match the source movement"
          end
        end

        def validate_reversible_entry!(source, action, entry)
          unless entry.transaction? && entry.transaction.kind == "standard" &&
              !entry.transaction.pending? && entry.import_id.nil? && entry.external_id.nil? &&
              entry.source.nil? && entry.idempotency_key == "abroa-source-#{source.id}" &&
              !entry.split_parent? && !entry.split_child? && !entry.transaction.transfer? &&
              !entry.recurring_allocations.exists? && !entry.transaction.attachments.attached? &&
              entry.reconciled_at.nil? && entry.unreconciled? &&
              !SourceRecord.where(entry: entry).where.not(id: source.id).exists? &&
              !RefundLink.active.where("original_entry_id = ? OR refund_entry_id = ?", entry.id, entry.id).exists? &&
              SourceAction.rollback_fingerprint_matches?(entry, action)
            raise Conflict, "Created entry changed or has later dependencies"
          end
        end
    end
  end
end
