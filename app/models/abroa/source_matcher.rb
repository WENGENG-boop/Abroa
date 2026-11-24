module Abroa
  class SourceMatcher
    Result = Data.define(:action, :reason, :candidate_ids, :entry_id)
    BANK_KINDS = %w[bank_provider bank_statement].freeze
    PAYMENT_KINDS = %w[alipay_statement wechat_statement].freeze
    DATE_WINDOW = 3
    MAX_CANDIDATES = 100

    # Pure decision boundary. A separate write service must recheck this result
    # under account/source/entry locks; a suggestion is never permission to mutate.
    def self.call(user:, source:)
      unless user&.active? && !user.guest? && source.persisted? && source.family_id == user.family_id
        raise ActiveRecord::RecordNotFound
      end
      if source.account_id
        account = user.family.accounts.writable_by(user).find(source.account_id)
        raise ActiveRecord::RecordNotFound unless AccountPolicy.new(user, account).permits?(:write)
      end
      return review("account_unidentified") unless account
      return review("source_not_postable") unless source.postable?
      return review("source_conflict") if source.observations.where(status: "conflict").exists?
      return review("not_bank_funded_payment") unless PAYMENT_KINDS.include?(source.source_kind) &&
        source.normalized["funding_kind"] == "bank_account" &&
        source.normalized["transaction_kind"] == "payment" && source.direction == "outflow"

      dates = (source.local_date - DATE_WINDOW)..(source.local_date + DATE_WINDOW)
      entries = account.entries.where(entryable_type: "Transaction", parent_entry_id: nil,
        excluded: false, date: dates, currency: source.currency, amount: source.signed_amount)
        .excluding_pending.excluding_split_parents.excluding_scheduled.order(:id).limit(MAX_CANDIDATES + 1)
        .includes(:entryable).to_a
      ids = entries.map(&:id)
      return review("too_many_candidates", ids.first(MAX_CANDIDATES)) if entries.size > MAX_CANDIDATES
      return review("no_existing_bank_entry") if entries.empty?
      return review("ambiguous_candidates", ids) unless entries.one?

      entry = entries.first
      return review("ineligible_entry", ids) unless entry.transaction.kind == "standard"
      reference = source.normalized["reference"].presence
      return review("missing_explicit_reference", ids) unless reference
      bank_evidence = SourceRecord.where(
        family_id: source.family_id, account_id: account.id, entry_id: entry.id,
        source_kind: BANK_KINDS, status: %w[linked posted], currency: source.currency,
        direction: source.direction, amount: source.amount, local_date: dates
      ).where("normalized ->> 'provider_status' = ?", "posted")
        .where("normalized ->> 'reference' = ?", reference)
        .limit(2).to_a
      unless bank_evidence.one? && !bank_evidence.first.observations.where(status: "conflict").exists?
        return review("unconfirmed_shared_reference", ids)
      end
      # Distinct wallet orders claiming the same bank movement are ambiguous,
      # even when the first order was previously linked.
      competing_orders = SourceRecord.where(
        family_id: source.family_id, account_id: account.id, source_kind: PAYMENT_KINDS,
        currency: source.currency, direction: source.direction, amount: source.amount, local_date: dates
      ).where.not(id: source.id).where.not(status: %w[ignored reversed])
        .where("normalized ->> 'provider_status' = ?", "posted")
        .where("normalized ->> 'reference' = ?", reference)
      if competing_orders.exists? || SourceRecord.where(entry_id: entry.id, source_kind: PAYMENT_KINDS).where.not(id: source.id).exists?
        return review("competing_payment_orders", ids)
      end
      if AccountProfile.where(account_id: account.id).where.not(wallet_kind: nil).exists?
        return review("not_bank_account", ids)
      end

      Result.new(action: "link", reason: "unique_explicit_reference", candidate_ids: ids.freeze, entry_id: entry.id)
    end

    def self.review(reason, ids = [])
      Result.new(action: "review", reason: reason, candidate_ids: ids.freeze, entry_id: nil)
    end
    private_class_method :review
  end
end
