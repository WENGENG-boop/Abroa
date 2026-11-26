module Abroa
  # A read-only project projection. The original Entry remains the single ledger fact.
  class ProjectSummary
    MAX_ROWS = 10_000

    def self.for_user(user, project_id, start_on:, end_on:, currency:)
      project = StudyProject.find_for!(user, project_id)
      begin
        start_date, end_date = Date.iso8601(start_on), Date.iso8601(end_on)
      rescue TypeError, Date::Error
        raise ArgumentError, "Expected valid ISO dates"
      end
      raise ArgumentError, "Invalid summary period" if start_date < project.start_on || end_date < start_date ||
        (project.end_on && end_date > project.end_on) || (end_date - start_date).to_i > 3660
      target = Decimal.currency!(currency)
      rows = project.allocations.visible_to(user).where(entry_date: start_date..end_date)
        .order(:id).limit(MAX_ROWS + 1).includes(:project, entry: [ :account, :entryable ]).to_a
      raise ArgumentError, "Summary is too large" if rows.size > MAX_ROWS
      # Every allocation of an Entry shares its global available amount; the
      # consistency check must include allocations from all projects. Preload
      # the exact same unscoped totals once rather than running one SUM per row.
      entry_ids = rows.filter_map(&:entry_id).uniq
      allocated_totals = EntryAllocation.where(entry_id: entry_ids).group(:entry_id).sum(:amount)
      split_parents = Entry.where(parent_entry_id: entry_ids).distinct.pluck(:parent_entry_id).index_with { true }
      quotes = {}
      total = BigDecimal("0")
      missing = []
      rows.each do |allocation|
        unless allocation.consistent?(allocated_total: allocated_totals.fetch(allocation.entry_id, 0),
          split_parent: split_parents.key?(allocation.entry_id))
          missing << { allocation_id: allocation.id, reason: "ledger_changed" }
          next
        end
        key = [ allocation.currency, target, allocation.entry_date ]
        quote = quotes[key] ||= RateSnapshot.quote(from: allocation.currency, to: target, date: allocation.entry_date)
        if quote.missing?
          missing << { allocation_id: allocation.id, reason: "missing_rate" }
          next
        end
        converted = quote.convert(allocation.amount)
        total += allocation.direction == "expense" ? converted : -converted
      end
      precision = Money::Currency.new(target).default_precision
      {
        project_id: project.id, start_on: start_date.iso8601, end_on: end_date.iso8601,
        currency: target, net_consumption: missing.any? ? nil : total.round(precision).to_s("F"),
        allocated_entry_count: rows.size, incomplete: missing.any?, missing: missing
      }
    end
  end
end
