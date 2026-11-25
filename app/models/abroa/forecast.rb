module Abroa
  # Deterministic, read-only projection over Sure's authoritative accounts and
  # validated P2/P3/P4 obligations. Simulations never create Ledger entries.
  class Forecast
    VERSION = "p4-forecast-1.0.0"
    DAYS = 180
    SCENARIOS = %w[conservative planned_funding stress].freeze
    ZERO = BigDecimal("0")

    def self.simulate(opening_balance:, daily_consumption:, currency:, as_of:,
      fixed_events: [], planned_events: [], scenario: "conservative",
      living_multiplier: "1", rent_multiplier: "1", funding_delay_days: 0,
      fx_shock_pct: "0", include_timeline: false)
      code = Decimal.currency!(currency)
      date = checked_date!(as_of)
      raise ArgumentError, "Unknown scenario" unless SCENARIOS.include?(scenario)
      opening = Decimal.money!(opening_balance)
      daily = Decimal.money!(daily_consumption, nonnegative: true)
      living = checked_factor!(living_multiplier, label: "living")
      rent = checked_factor!(rent_multiplier, label: "rent")
      shock = Decimal.parse!(fx_shock_pct)
      raise ArgumentError, "Invalid FX stress" unless shock.between?(ZERO, BigDecimal("1"))
      raise ArgumentError, "Invalid funding delay" unless funding_delay_days.is_a?(Integer) &&
        funding_delay_days.between?(0, DAYS)
      fixed = checked_events!(fixed_events, type: :expense)
      planned = checked_events!(planned_events, type: :income)

      if scenario == "stress"
        living *= BigDecimal("1.25")
        rent *= BigDecimal("1.15")
        shock = BigDecimal("0.1") if shock.zero?
      end
      daily *= living
      daily = daily.round(4)
      fixed_by_day = Hash.new(ZERO)
      fixed.each do |row|
        cost = row[:amount]
        cost *= rent if row[:rent_sensitive]
        cost *= (1 + shock) if row[:fx_exposed]
        fixed_by_day[row[:day]] += cost.round(4)
      end
      income_by_day = Hash.new(ZERO)
      if scenario == "planned_funding"
        planned.each do |row|
          day = row[:day] + funding_delay_days
          if day <= DAYS
            credit = row[:fx_exposed] ? (row[:amount] * (1 - shock)).round(4) : row[:amount]
            income_by_day[day] += credit
          end
        end
      end

      balance = opening
      first_shortage = balance.negative? ? date : nil
      minimum = opening
      snapshots = { day_10: nil, day_30: nil, day_90: nil, day_180: nil }
      timeline = []
      (1..DAYS).each do |day|
        balance += income_by_day[day] - daily - fixed_by_day[day]
        first_shortage ||= date + day if balance.negative?
        minimum = [ minimum, balance ].min
        snapshots[:"day_#{day}"] = balance.to_s("F") if [ 10, 30, 90, 180 ].include?(day)
        if include_timeline
          timeline << { date: (date + day).iso8601, balance: balance.to_s("F"),
            expected_spending: (daily + fixed_by_day[day]).to_s("F"),
            hypothetical_income: income_by_day[day].to_s("F") }
        end
      end

      first_amount = if first_shortage.nil?
        nil
      elsif first_shortage == date
        opening.abs
      else
        day = (first_shortage - date).to_i
        (timeline.empty? ? compute_balance!(opening, daily, fixed_by_day, income_by_day, day) :
          BigDecimal(timeline[day - 1][:balance])).abs
      end
      projected_cost = daily * DAYS + fixed_by_day.values.sum(ZERO)
      buffer = daily * 30
      gap = [ ZERO, buffer - BigDecimal(snapshots[:day_30]) ].max
      {
        algorithm_version: VERSION, currency: code, as_of: date.iso8601,
        scenario: scenario, horizon_days: DAYS,
        opening_balance: opening.to_s("F"),
        daily_consumption: daily.to_s("F"),
        balances: snapshots, first_shortage_on: first_shortage&.iso8601,
        first_shortage_amount: first_amount&.to_s("F"),
        runway_days: first_shortage ? [ (first_shortage - date).to_i - 1, 0 ].max : nil,
        projected_cost_180d: projected_cost.to_s("F"),
        minimum_projected_balance: minimum.to_s("F"),
        reserve_warning: opening < buffer,
        suggested_top_up_30d: gap.to_s("F"),
        assumed_future_income: income_by_day.values.sum(ZERO).to_s("F"),
        assumptions: {
          historical_consumption_repeats_daily: true,
          fixed_fees_are_paid_on_due_date: true,
          planned_receipts_are_hypothetical: scenario == "planned_funding",
          living_multiplier: living.to_s("F"),
          rent_multiplier: rent.to_s("F"),
          funding_delay_days: funding_delay_days,
          fx_shock_pct: shock.to_s("F"),
          cash_excludes_receivables_and_reserved_pool_targets: true
        },
        timeline: include_timeline ? timeline : nil
      }
    end

    def self.for_student(user, project_id: nil, as_of: Date.current, currency: nil,
      account_ids: nil, scenario: "conservative", living_multiplier: "1",
      rent_multiplier: "1", funding_delay_days: 0, fx_shock_pct: "0",
      include_timeline: false, include_personal_debts: true, funding_parent_id: nil)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      date = checked_date!(as_of)
      raise ArgumentError, "Unknown scenario" unless SCENARIOS.include?(scenario)
      checked_factor!(living_multiplier, label: "living")
      checked_factor!(rent_multiplier, label: "rent")
      shock = Decimal.parse!(fx_shock_pct)
      raise ArgumentError, "Invalid FX stress" unless shock.between?(ZERO, BigDecimal("1"))
      raise ArgumentError, "Invalid funding delay" unless funding_delay_days.is_a?(Integer) &&
        funding_delay_days.between?(0, DAYS)
      raise ArgumentError, "Cannot forecast with future or very old source date" if
        date > Date.current || date < Date.current - 365
      project = project_id ? StudyProject.find_for!(user, project_id) : nil
      code = Decimal.currency!(currency || project&.currency || user.family.currency)
      raise ArgumentError, "Invalid account IDs" if account_ids &&
        (!account_ids.is_a?(Array) || account_ids.size > 100 || account_ids.any? { |id| !UuidFormat.valid?(id) })
      permitted = user.family.accounts.accessible_by(user)
        .where(accountable_type: "Depository", owner_id: user.id)
      if project
        permitted = permitted.where(id: ProjectAccount.where(
          family_id: user.family_id, project_id: project.id).select(:account_id))
      end
      requested = account_ids&.uniq
      cash_scope = requested ? permitted.where(id: requested) : permitted
      accounts = cash_scope.order(:id).limit(501).to_a
      raise ArgumentError, "Too many cash accounts" if accounts.size > 500
      raise ActiveRecord::RecordNotFound if requested && accounts.size != requested.size

      missing = []
      assumptions = []
      balance = ZERO
      accounts.each do |account|
        quote = RateSnapshot.quote(from: account.currency, to: code, date: date)
        if quote.missing?
          missing << { kind: "cash_fx", currency: account.currency, as_of: date.iso8601 }
        else
          balance += quote.convert(account.balance)
        end
      end
      history_start = date - 30
      history_end = date - 1
      baseline = ZERO
      if accounts.empty?
        assumptions << "no_history_zero_consumption_baseline"
      else
        statement = NetConsumption.for_user(user, start_on: history_start,
          end_on: history_end, currency: code, account_ids: accounts.map(&:id),
          include_debts: include_personal_debts)
        baseline_string = statement.dig(:totals, :net_consumption)
        missing << { kind: "historical_consumption_fx" } if statement[:incomplete] || baseline_string.nil?
        fixed_history = historical_fee_net!(user, project_id: project&.id,
          account_ids: accounts.map(&:id), from: history_start, to: history_end,
          currency: code, missing: missing)
        baseline = baseline_string ? ([ ZERO,
          Decimal.money!(baseline_string) - fixed_history ].max / 30).round(4) : ZERO
        unless Entry.where(account_id: accounts.map(&:id), date: history_start..history_end).exists?
          assumptions << "no_history_zero_consumption_baseline"
        end
      end

      anomalies = []
      if accounts.any? && baseline.positive?
        recent_from = date - 7
        recent_report = NetConsumption.for_user(user, start_on: recent_from,
          end_on: history_end, currency: code, account_ids: accounts.map(&:id),
          include_debts: include_personal_debts)
        if recent_report[:incomplete]
          missing << { kind: "recent_spending_fx" }
        else
          recent_fixed = historical_fee_net!(user, project_id: project&.id,
            account_ids: accounts.map(&:id), from: recent_from, to: history_end,
            currency: code, missing: missing)
          recent_daily = ([ ZERO,
            Decimal.money!(recent_report.dig(:totals, :net_consumption)) - recent_fixed ].max / 7).round(4)
          if recent_daily > baseline * 2 && recent_daily - baseline >= BigDecimal("5")
            anomalies << { kind: "recent_spending_spike",
              recent_daily_consumption: recent_daily.to_s("F"),
              historical_daily_baseline: baseline.to_s("F"),
              threshold_multiple: "2.0" }
          end
        end
      end

      fixed = []
      planned = []
      fee_scope = FeePlan.for_user(user).where(status: "active")
      fee_scope = fee_scope.where(project_id: project.id) if project
      fees = fee_scope.limit(501).includes(:installments).to_a
      raise ArgumentError, "Too many fees" if fees.size > 500
      fees.each do |fee|
        installments = fee.installments.select { |item| item.state == "confirmed" }
        assumptions << "missing_fee_schedule:#{fee.id}" if installments.empty? &&
          fee.outstanding_amount.positive?
        installments.each do |item|
          next if item.outstanding_amount.zero?
          amount = convert!(item.outstanding_amount, from: fee.currency, to: code, date: date,
            missing: missing, kind: "fee_fx")
          next unless amount
          day = event_day(item.due_on, date)
          fixed << { day: day, amount: amount.to_s("F"), label: "Due installment",
          fx_exposed: fee.currency != code,
          rent_sensitive: %w[rent housing].include?(fee.kind) } if day <= DAYS
        end
      end

      debt_scope = include_personal_debts ?
        PersonalDebt.for_user(user).where.not(status: "cancelled") : PersonalDebt.none
      debt_scope = debt_scope.where(project_id: project.id) if project
      debts = debt_scope.limit(501).includes(:settlements).to_a
      raise ArgumentError, "Too many personal claims" if debts.size > 500
      debts.each do |debt|
        next if debt.outstanding_amount.zero?
        if !debt.consistent?
          missing << { kind: "inconsistent_personal_debt", id: debt.id }
          next
        end
        unless debt.due_on
          assumptions << "missing_debt_due_date:#{debt.id}"
          next
        end
        amount = convert!(debt.outstanding_amount, from: debt.currency, to: code, date: date,
          missing: missing, kind: "debt_fx")
        next unless amount
        day = event_day(debt.due_on, date)
        next if day > DAYS
        event = { day: day, amount: amount.to_s("F"), label: "Personal obligation",
          fx_exposed: debt.currency != code }
        (debt.direction == "payable" ? fixed : planned) << event
      end

      funding_scope = FundingPlan.for_student(user).where.not(status: %w[cancelled rejected])
      funding_scope = funding_scope.where(project_id: project.id) if project
      funding_scope = funding_scope.where(parent_user_id: funding_parent_id) if funding_parent_id
      plans = funding_scope.limit(501).to_a
      raise ArgumentError, "Too many funding plans" if plans.size > 500
      plans.each do |plan|
        unless plan.evidence_consistent?
          missing << { kind: "funding_evidence_changed", id: plan.id }
          next
        end
        left = plan.outstanding_total
        next if left.zero?
        amount = convert!(left, from: plan.currency, to: code, date: date,
          missing: missing, kind: "funding_fx")
        next unless amount
        dates = plan.schedule_dates.select { |d| d >= date }.sort
        if dates.empty? && plan.scheduled_on < date
          assumptions << "overdue_planned_funding:#{plan.id}"
          dates = [ date + 1 ]
        end
        next if dates.empty?
        per_date = (amount / dates.length).round(4)
        remainder = amount
        dates.each_with_index do |d, idx|
          share = idx == dates.length - 1 ? remainder : per_date
          remainder -= share
          day = event_day(d, date)
          planned << { day: day, amount: share.to_s("F"), label: "Planned allowance",
            fx_exposed: plan.currency != code } if day <= DAYS
        end
      end

      study_total = nil
      study_remaining = nil
      if project && project.end_on
        full_days = (project.end_on - project.start_on).to_i + 1
        remaining_days = [ 0, (project.end_on - date).to_i + 1 ].max
        raise ArgumentError, "Project duration too large" if full_days > 3660
        fee_total = ZERO
        fee_remaining = ZERO
        fees.each do |fee|
          all = convert!(fee.amount_due, from: fee.currency, to: code,
            date: date, missing: missing, kind: "study_cost_fx")
          unpaid = convert!(fee.outstanding_amount, from: fee.currency, to: code,
            date: date, missing: missing, kind: "study_cost_fx")
          next unless all && unpaid
          fee_total += all
          fee_remaining += unpaid
        end
        study_total = (baseline * full_days + fee_total).round(4)
        study_remaining = (baseline * remaining_days + fee_remaining).round(4)
        assumptions << "study_total_is_baseline_extrapolation_not_historical_cash" if
          full_days.positive?
      end

      project_ids = project ? [ project.id ] : StudyProject.for_user(user).select(:id)
      selected_entries = Entry.where(account_id: accounts.map(&:id)).select(:id)
      selected_installments = FeeInstallment.where(fee_plan_id: fees.map(&:id)).select(:id)
      data_input = [ user.id, project&.id, code, date, scenario,
        accounts.map { |a| [ a.id, a.balance.to_s("F"), a.updated_at&.to_i ] },
        Entry.where(account_id: accounts.map(&:id)).count,
        Entry.where(account_id: accounts.map(&:id)).maximum(:updated_at)&.to_i,
        fees.map { |fee| [ fee.id, fee.updated_at&.to_i,
          fee.amount_due.to_s("F"), fee.outstanding_amount.to_s("F"),
          fee.installments.map { |i| [ i.id, i.outstanding_amount.to_s("F") ] } ] },
        debts.map { |debt| [ debt.id, debt.lock_version, debt.outstanding_amount.to_s("F") ] },
        plans.map { |plan| [ plan.id, plan.lock_version, plan.status,
          plan.outstanding_total.to_s("F"), plan.updated_at&.to_i ] },
        EntryAllocation.where(family_id: user.family_id,
          project_id: project_ids).maximum(:updated_at)&.to_f,
        FeeSettlement.where(family_id: user.family_id,
          fee_installment_id: selected_installments).maximum(:updated_at)&.to_f,
        RefundLink.where(family_id: user.family_id,
          original_entry_id: selected_entries).maximum(:updated_at)&.to_f,
        DebtSettlement.where(family_id: user.family_id,
          personal_debt_id: debts.map(&:id)).maximum(:updated_at)&.to_f,
        ExchangeRate.maximum(:updated_at)&.to_i ]
      version = Digest::SHA256.hexdigest(JSON.generate(data_input))
      unless missing.empty?
        return { algorithm_version: VERSION, data_version: version,
          data_at: Time.current.utc.iso8601(6), currency: code,
          as_of: date.iso8601, project_id: project&.id,
          incomplete: true, missing: missing, assumptions: assumptions,
          opening_balance: nil, daily_consumption: nil,
          balances: { day_10: nil, day_30: nil, day_90: nil, day_180: nil },
          first_shortage_on: nil, runway_days: nil }
      end
      result = simulate(opening_balance: balance, daily_consumption: baseline,
        currency: code, as_of: date, fixed_events: fixed, planned_events: planned,
        scenario: scenario, living_multiplier: living_multiplier,
        rent_multiplier: rent_multiplier, funding_delay_days: funding_delay_days,
        fx_shock_pct: fx_shock_pct, include_timeline: include_timeline)
      result.merge(project_id: project&.id, data_version: version,
        data_at: Time.current.utc.iso8601(6),
        incomplete: assumptions.any? { |item| item.start_with?("no_history", "missing_", "overdue_") },
        missing: [], data_assumptions: assumptions,
        anomalies: anomalies,
        estimated_study_total_cost: study_total&.to_s("F"),
        estimated_study_remaining_cost: study_remaining&.to_s("F"),
        cache_policy: "no_persistent_cache",
        cash_account_count: accounts.size, unpaid_fee_count: fixed.size,
        unreceived_future_event_count: planned.size)
    end

    def self.for_parent!(parent, project_id, **options)
      raise ActiveRecord::RecordNotFound unless parent&.active? &&
        Profile.for_user(parent).parent_enabled?
      project = ParentOverview.authorized_project!(parent, project_id, "forecasts_read")
      raise ActiveRecord::RecordNotFound unless
        Grant.allowed?(parent, project, "account_balance") &&
          Grant.allowed?(parent, project, "fees_read")
      result = for_student(project.owner, project_id: project.id,
        currency: project.currency, include_personal_debts: false,
        funding_parent_id: parent.id,
        **options.except(:project_id, :currency, :account_ids, :include_timeline))
      # Deliberately omit account identifiers, daily transactions and debt data.
      result.except(:timeline, :cash_account_count, :unpaid_fee_count,
        :unreceived_future_event_count, :data_assumptions, :anomalies)
    end

    class << self
      private
        def checked_date!(value)
          raise ArgumentError, "Expected Date" unless value.is_a?(Date)
          value
        end

        def checked_factor!(value, label:)
          number = Decimal.parse!(value)
          raise ArgumentError, "Invalid #{label} multiplier" unless
            number.between?(BigDecimal("0.5"), BigDecimal("5"))
          number
        end

        def checked_events!(events, type:)
          raise ArgumentError, "Expected limited events" unless events.is_a?(Array) && events.size <= 1000
          events.map do |raw|
            row = raw.to_h.symbolize_keys
            day = row[:day]
            raise ArgumentError, "Expected day within 180" unless day.is_a?(Integer) &&
              day.between?(1, DAYS)
            amount = Decimal.money!(row.fetch(:amount), nonnegative: true)
            raise ArgumentError, "Event label too long" if row[:label] && row[:label].to_s.bytesize > 120
            %i[fx_exposed rent_sensitive].each do |flag|
              raise ArgumentError, "Invalid event flag" unless [ nil, true, false ].include?(row[flag])
            end
            { day: day, amount: amount, label: row[:label], type: type,
              fx_exposed: !!row[:fx_exposed], rent_sensitive: !!row[:rent_sensitive] }
          end
        end

        # Fixed installments already represented in P2 are not part of the
        # repeatable daily living-spend baseline, preventing double counting.
        def historical_fee_net!(user, project_id:, account_ids:, from:, to:, currency:, missing:)
          scope = FeeSettlement.where(family_id: user.family_id, source_date: from..to)
            .where(fee_installment_id: FeeInstallment.for_user(user).select(:id))
          if project_id
            scope = scope.where(fee_installment_id: FeeInstallment.where(
              fee_plan_id: FeePlan.for_user(user).where(project_id: project_id).select(:id)).select(:id))
          end
          rows = scope.limit(2001).includes(:allocation, :refund_link).to_a
          raise ArgumentError, "Excessive historical fixed-payment data" if rows.size > 2000
          total = ZERO
          rows.each do |settlement|
            unless settlement.consistent?
              missing << { kind: "inconsistent_fee_settlement" }
              next
            end
            entry = settlement.kind == "payment" ?
              settlement.allocation.entry : settlement.refund_link.refund_entry
            next unless account_ids.include?(entry.account_id)
            native = settlement.kind == "payment" ?
              settlement.amount : settlement.refund_link.refund_amount
            converted = convert!(native, from: entry.currency, to: currency,
              date: entry.date, missing: missing, kind: "historical_fee_fx")
            next unless converted
            total += settlement.kind == "payment" ? converted : -converted
          end
          total
        end

        def compute_balance!(opening, daily, expenses, income, day)
          (1..day).reduce(opening) { |amount, idx| amount + income[idx] - daily - expenses[idx] }
        end

        def event_day(due, as_of)
          [ 1, (due - as_of).to_i ].max
        end

        def convert!(amount, from:, to:, date:, missing:, kind:)
          quote = RateSnapshot.quote(from: from, to: to, date: date)
          if quote.missing?
            missing << { kind: kind, from_currency: from, to_currency: to, as_of: date.iso8601 }
            nil
          else
            quote.convert(amount).round(4)
          end
        end
    end
  end
end
