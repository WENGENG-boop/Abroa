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
              evidence: { "source_version" => source.lock_version, "proposed_action" => decision.action })
          end
          next existing
        end
        create!(family: family, source_record: source, reason_code: decision.reason,
          candidate_ids: decision.candidate_ids,
          evidence: { "source_version" => source.lock_version, "proposed_action" => decision.action })
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
        case resolution
        when "create", "link"
          resolved_kind = validate_financial_source!(source, account, movement_kind)
          if resolution == "create"
            validate_creation!(source, account)
            entry = account.entries.create!(entryable: Transaction.new(kind: "standard",
              extra: source.payment_channel.present? ? { "abroa" => { "payment_channel" => source.payment_channel } } : {}),
              amount: source.signed_amount, currency: source.currency, date: source.local_date,
              name: source.normalized.fetch("description"), import_locked: true,
              idempotency_key: "abroa-source-#{source.id}")
          else
            entry = account.entries.find(target_entry_id)
            entry.lock!
            transaction = entry.transaction if entry.transaction?
            transaction&.lock!
            validate_link!(source, entry)
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
        next action if action.reversed_at?
        unless action.actor_id == user.id &&
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
          if action.operation == "create"
            validate_reversible_entry!(source, action, entry)
            source.update!(entry: nil, status: "reversed")
            entry.destroy!
            ActiveRecord.after_all_transactions_commit { entry.sync_account_later }
          else
            if action.after_data["channel_added"]
              if SourceRecord.where(entry: entry).where.not(id: source.id).where(payment_channel: source.payment_channel).exists? ||
                  SourceAction.fingerprint(entry) != action.after_data["fingerprint"]
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

    def payload
      { id: id, source_record_id: source_record_id, reason_code: reason_code,
        candidate_ids: candidate_ids, status: status, lock_version: lock_version,
        proposed_action: evidence["proposed_action"] }
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
          [ source, account ]
        end

        def validate_financial_source!(source, account, movement_kind)
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
          if source.normalized["funding_kind"] == "wallet"
            profile = AccountProfile.find_by(account: account, family_id: source.family_id)
            unless profile && profile.wallet_kind == source.payment_channel
              raise ArgumentError, "A wallet-funded payment requires the matching wallet account"
            end
          end
          kind
        end

        def validate_creation!(source, account)
          if source.source_kind == "bank_provider" ||
              (SourceMatcher::PAYMENT_KINDS.include?(source.source_kind) &&
                source.normalized["funding_kind"] != "wallet")
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
              SourceAction.fingerprint(entry) == action.after_data["fingerprint"]
            raise Conflict, "Created entry changed or has later dependencies"
          end
        end
    end
  end
end
