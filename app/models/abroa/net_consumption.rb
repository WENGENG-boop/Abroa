module Abroa
  # Read-only standard-consumption projection, separate from Sure's original
  # income statement. Linked refunds reduce spending on their actual receipt
  # date. Other credits are unallocated inflows, not asserted to be income.
  class NetConsumption
    MAX_DAYS = 3660
    MAX_ACCOUNTS = 100
    MAX_ROWS = 10_000
    ZERO = BigDecimal("0")
    FIELDS = %i[gross_consumption refunds unallocated_inflows].freeze

    def self.for_user(user, start_on:, end_on:, currency:, account_ids: nil)
      raise ActiveRecord::RecordNotFound unless user&.active?
      unless start_on.instance_of?(Date) && end_on.instance_of?(Date) &&
          start_on.year.positive? && start_on <= end_on && end_on <= Date.current &&
          (end_on - start_on).to_i < MAX_DAYS
        raise ArgumentError, "Invalid consumption report period"
      end
      currency = Decimal.currency!(currency)
      accounts = user.family.accounts.accessible_by(user)
      if account_ids
        unless account_ids.is_a?(Array) && account_ids.any? && account_ids.size <= MAX_ACCOUNTS &&
            account_ids.all? { |id| UuidFormat.valid?(id) } && account_ids.uniq.size == account_ids.size
          raise ArgumentError, "Expected distinct accessible account IDs"
        end
        accounts = accounts.where(id: account_ids)
      end
      selected = accounts.order(:id).limit(MAX_ACCOUNTS + 1).to_a
      raise ArgumentError, "Select a narrower account scope" if selected.size > MAX_ACCOUNTS
      raise ActiveRecord::RecordNotFound if account_ids && selected.size != account_ids.size
      ids = selected.map(&:id)
      allowed = Entry.where(account_id: ids)
      entries = allowed.where(entryable_type: "Transaction", entryable_id: Transaction.standard.select(:id),
        excluded: false, date: start_on..end_on).excluding_pending.excluding_split_parents
        .excluding_scheduled.order(:id).limit(MAX_ROWS + 1).to_a
      raise ArgumentError, "Select a shorter report period" if entries.size > MAX_ROWS

      buckets = Hash.new { |h, key| h[key] = { gross_consumption: ZERO, refunds: ZERO, unallocated_inflows: ZERO } }
      entries.each do |entry|
        amounts = buckets[[entry.date, entry.currency]]
        if entry.amount.positive?
          amounts[:gross_consumption] += entry.amount
        elsif entry.amount.negative?
          amounts[:unallocated_inflows] -= entry.amount
        end
      end

      # Both sides must belong to the selected, accessible account scope.
      # Never disclose a private account's refund association.
      credits = entries.select { |entry| entry.amount.negative? }.index_by(&:id)
      links = RefundLink.active.where(family_id: user.family_id, original_entry_id: allowed.select(:id),
        refund_entry_id: credits.keys).order(:id).limit(MAX_ROWS + 1)
        .includes(:rate_snapshot, original_entry: [:account, :entryable], refund_entry: [:account, :entryable]).to_a
      raise ArgumentError, "Too many refund allocations; select a shorter report period" if links.size > MAX_ROWS
      invalid = Set.new
      inconsistent_count = 0
      links.each do |link|
        credit = credits.fetch(link.refund_entry_id)
        key = [credit.date, credit.currency]
        unless link.consistent?
          invalid.add(key)
          inconsistent_count += 1
          next
        end
        # Use the actual refund currency/amount, not the amount allocated
        # back to a purchase in a different currency.
        buckets[key][:refunds] += link.refund_amount
        buckets[key][:unallocated_inflows] -= link.refund_amount
      end

      totals = FIELDS.index_with { ZERO }
      incomplete_fields = Set.new
      rates = []
      buckets.sort.each do |(date, from), amounts|
        if invalid.include?([date, from])
          incomplete_fields.merge(%i[refunds unallocated_inflows])
        end
        next if amounts.values.all?(&:zero?)
        quote = RateSnapshot.quote(from: from, to: currency, date: date)
        rates << quote.payload
        FIELDS.each do |field|
          next if amounts[field].zero?
          if quote.missing?
            incomplete_fields.add(field)
          else
            totals[field] += quote.convert(amounts[field])
          end
        end
      end
      # A refund rate may be missing even if the valid portion and the
      # ordinary credit net to zero in one bucket; each component is tracked
      # independently, so no missing nonzero amount becomes a numeric zero.
      gross, refunds = totals.values_at(:gross_consumption, :refunds)
      precision = Money::Currency.new(currency).default_precision
      display = ->(amount) { amount.round(precision).to_s("F") }
      values = FIELDS.to_h do |field|
        [field, incomplete_fields.include?(field) ? nil : display.call(totals[field])]
      end
      values[:net_consumption] = if incomplete_fields.intersect?(Set[:gross_consumption, :refunds])
        nil
      else
        display.call(gross - refunds)
      end
      {
        start_on: start_on.iso8601, end_on: end_on.iso8601, currency: currency,
        account_ids: ids, totals: values, incomplete: incomplete_fields.any?,
        inconsistent_refund_count: inconsistent_count, rates: rates
      }
    end
  end
end
