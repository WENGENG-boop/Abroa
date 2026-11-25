module Abroa
  # Reclassifies P2 project allocations according to the P4 ownership of
  # cashflows. No entry is created/rewritten; conversion is historical.
  class ProjectDebtRecognition
    ZERO = BigDecimal("0")

    def self.adjustment!(user, project:, debts:, from:, to:, currency:, missing:)
      delta = ZERO
      debts.each do |debt|
        if !debt.consistent?
          missing << { kind: "project_debt_evidence_changed" }
          next
        end
        if debt.incurred_on.between?(from, to)
          delta += origin_adjustment!(user, project, debt, currency: currency, missing: missing)
        end
        debt.settlements.where(entry_date: from..to).order(:id).limit(501).each do |settlement|
          unless settlement.consistent?
            missing << { kind: "project_settlement_evidence_changed" }
            next
          end
          entry = settlement.entry
          allocation = allocated_for(user, project, entry.id)
          next if allocation.zero?
          if settlement.kind == "source_refund"
            # P2 counts the whole merchant refund as negative expenditure;
            # only the other person's share must be reassigned to their claim.
            share = (settlement.applied_amount *
              [ allocation, settlement.native_amount ].min / settlement.native_amount).round(4)
            delta += converted!(share, from: debt.currency, to: currency,
              date: settlement.entry_date, missing: missing)
          else
            native = [ allocation, settlement.native_amount ].min
            value = converted!(native, from: entry.currency, to: currency,
              date: entry.date, missing: missing)
            # P2 cash inflows reduce project spending, while loan repayments
            # cannot reduce expenses; debt repayments are not new expenses.
            delta += entry.amount.negative? ? value : -value
          end
        end
      end
      delta
    end

    class << self
      private
        def origin_adjustment!(user, project, debt, currency:, missing:)
          if debt.kind == "paid_by_other"
            return converted!(debt.personal_amount, from: debt.currency, to: currency,
              date: debt.incurred_on, missing: missing)
          end
          return ZERO unless debt.source_entry
          portion = allocated_for(user, project, debt.source_entry_id)
          return ZERO if portion.zero?
          native = case debt.kind
          when "paid_for_other" then -[ debt.other_amount, portion ].min
          when "lent" then -[ debt.principal_amount, portion ].min
          when "borrowed" then [ debt.principal_amount, portion ].min
          else ZERO
          end
          converted!(native, from: debt.currency, to: currency,
            date: debt.incurred_on, missing: missing)
        end

        def allocated_for(user, project, entry_id)
          project.allocations.visible_to(user).where(entry_id: entry_id).sum(:amount)
        end

        def converted!(amount, from:, to:, date:, missing:)
          quote = RateSnapshot.quote(from: from, to: to, date: date)
          if quote.missing?
            missing << { kind: "project_debt_fx", currency: from, report_currency: to }
            ZERO
          else
            quote.convert(amount).round(4)
          end
        end
    end
  end
end
