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
      rows = project.allocations.visible_to(user).where(entry_date: start_date..end_date).order(:id).limit(MAX_ROWS + 1).to_a
      raise ArgumentError, "Summary is too large" if rows.size > MAX_ROWS
      total = BigDecimal("0")
      missing = []
      rows.each do |allocation|
        unless allocation.consistent?
          missing << { allocation_id: allocation.id, reason: "ledger_changed" }
          next
        end
        quote = RateSnapshot.quote(from: allocation.currency, to: target, date: allocation.entry_date)
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
