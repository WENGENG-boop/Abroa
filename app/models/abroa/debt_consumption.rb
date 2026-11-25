module Abroa
  # Recognition adjustments on top of Sure bank flows: third-party shares are
  # claims, not personal spending; paying a payable does not incur the cost twice.
  class DebtConsumption
    MAX_ROWS = 10_000
    ZERO = BigDecimal("0")

    def self.for_user(user, entries:, account_ids:, start_on:, end_on:)
      visible_entries = entries.index_by(&:id)
      adjustments = Hash.new { |h, k| h[k] = { net: ZERO, matched_credit: ZERO } }
      debts = PersonalDebt.for_user(user).where(incurred_on: ..end_on)
        .order(:id).limit(MAX_ROWS + 1).includes(:source_entry).to_a
      raise ArgumentError, "Debt projection exceeds row limit" if debts.size > MAX_ROWS
      debts.each do |debt|
        next if debt.status == "cancelled"
        raise ArgumentError, "Debt evidence changed" unless debt.consistent?
        if debt.incurred_on >= start_on
          key = [ debt.incurred_on, debt.currency ]
          case debt.kind
          when "paid_for_other"
            adjustments[key][:net] -= debt.other_amount if visible_entries.key?(debt.source_entry_id)
          when "lent"
            adjustments[key][:net] -= debt.principal_amount if visible_entries.key?(debt.source_entry_id)
          when "paid_by_other"
            adjustments[key][:net] += debt.personal_amount
          when "borrowed"
            if (entry = visible_entries[debt.source_entry_id])
              adjustments[[ entry.date, entry.currency ]][:matched_credit] += entry.amount.abs
            end
          end
        end
        settlements = debt.settlements.where(entry_date: start_on..end_on)
          .order(:id).limit(MAX_ROWS + 1).includes(:entry).to_a
        raise ArgumentError, "Debt settlement projection exceeds row limit" if settlements.size > MAX_ROWS
        settlements.each do |settlement|
          entry = visible_entries[settlement.entry_id]
          next unless entry
          key = [ entry.date, entry.currency ]
          if settlement.kind == "source_refund"
            # Sure RefundLink already removes this credit from income and
            # counts the full merchant refund against the original purchase.
            # Reassign the other person's share back from that refund.
            adjustments[key][:net] +=
              (settlement.native_amount * debt.other_amount / debt.source_amount.abs).round(4)
            next
          end
          if entry.amount.negative?
            adjustments[key][:matched_credit] += settlement.native_amount
          else
            adjustments[key][:net] -= settlement.native_amount
          end
        end
      end
      adjustments
    end
  end
end
