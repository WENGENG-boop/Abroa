module Abroa
  # Composes projections of existing Sure and Abroa ledger facts. This service
  # never writes entries and never treats debt, reserves or planned funds as cash.
  class FinancialReport
    VERSION = "p4-financial-report-1.0"
    ZERO = BigDecimal("0")
    MAX_RECORDS = 500

    def self.for_student!(user, scope:, project_id: nil, period_id: nil,
      start_on: nil, end_on: nil, currency: nil, account_ids: nil)
      raise ActiveRecord::RecordNotFound unless user&.active? && !user.guest?
      raise ArgumentError, "Expected personal or project scope" unless %w[personal project].include?(scope)
      raise ArgumentError, "Personal report cannot have project or study period" if
        scope == "personal" && (project_id || period_id)
      project = project_id ? StudyProject.find_for!(user, project_id) : nil
      raise ArgumentError, "Project required" if scope == "project" && project.nil?
      target = Decimal.currency!(currency || project&.currency || user.family.primary_currency_code)
      dates = student_dates!(project: project, period_id: period_id,
        start_on: start_on, end_on: end_on)
      from, to = dates
      accounts = authorized_cash_accounts!(user, project: project, account_ids: account_ids)
      ids = accounts.map(&:id)
      missing = []
      cash = cash_report!(user, from: from, to: to, currency: target,
        account_ids: ids, accounts: accounts, missing: missing)
      result = {
        algorithm_version: VERSION, data_at: Time.current.utc.iso8601(6),
        scope: scope, project_id: project&.id, period_id: period_id,
        start_on: from.iso8601, end_on: to.iso8601, currency: target,
        cash_flow: cash,
        bank_account_count: accounts.size,
        incomplete: false, missing: missing
      }
      debts = PersonalDebt.for_user(user).where.not(status: "cancelled")
      debts = debts.where(project_id: project.id) if project
      debts = bounded!(debts.where(incurred_on: ..to).order(:id))
      result[:receivables] = debt_aggregate!(debts.select { |d| d.direction == "receivable" },
        currency: target, date: to, missing: missing)
      result[:payables] = debt_aggregate!(debts.select { |d| d.direction == "payable" },
        currency: target, date: to, missing: missing)

      if project
        project_net = ProjectSummary.for_user(user, project.id,
          start_on: from.iso8601, end_on: to.iso8601, currency: target)
        missing.concat(project_net[:missing].map { |item| { kind: "project_allocation", evidence: item } })
        # P2 includes all linked cash flows. Debt recognition excludes
        # third-party shares, cash repayment noise and merchant-return shares.
        debt_delta = ProjectDebtRecognition.adjustment!(user, project: project,
          debts: debts, from: from, to: to, currency: target, missing: missing)
        debt_bad = missing.any? { |reason| reason[:kind].start_with?("project_debt", "project_settlement") }
        adjusted = project_net[:net_consumption] && !debt_bad ?
          (Decimal.parse!(project_net[:net_consumption]) + debt_delta) : nil
        result[:project] = {
          ledger_allocated_consumption: project_net[:net_consumption],
          personal_allocated_consumption: adjusted&.to_s("F"),
          allocation_count: project_net[:allocated_entry_count]
        }
        result[:budgets] = budgets!(user, project, from: from, to: to, currency: target, missing: missing)
        result[:fees] = fees!(user, project, currency: target, date: to, missing: missing)
        result[:pools] = pools!(user, project, currency: target, date: to, missing: missing)
        result[:funding] = funding!(user, project, currency: target, date: to, missing: missing)
      end
      result[:incomplete] = missing.any?
      result[:input_version] = Digest::SHA256.hexdigest([
        user.id, project&.id, from, to, target,
        ids.sort,
        accounts.map { |a| [ a.id, a.balance.to_s("F"), a.updated_at&.to_f ] },
        Entry.where(account_id: ids).maximum(:updated_at)&.to_f,
        project && EntryAllocation.where(project_id: project.id).maximum(:updated_at)&.to_f,
        debts.map { |debt| [ debt.id, debt.lock_version, debt.outstanding_amount.to_s("F") ] },
        ExchangeRate.maximum(:updated_at)&.to_f
      ].to_json)
      result
    end

    # Parent periods are whole calendar months or predeclared academic years or
    # terms. No arbitrarily short windows, account selectors or personal debts.
    def self.for_parent!(parent, project_id:, month: nil, period_id: nil, **untrusted)
      raise ArgumentError, "Arbitrary parent report filters are forbidden" if untrusted.any?
      raise ArgumentError, "Select a calendar month or year/term" if month.present? == period_id.present?
      project = ParentOverview.authorized_project!(parent, project_id, "summary")
      if month
        raise ArgumentError, "Invalid month" unless month.is_a?(String) && month.match?(/\A\d{4}-(0[1-9]|1[0-2])\z/)
        from = Date.iso8601("#{month}-01")
        to = from.end_of_month
      else
        raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(period_id)
        period = project.periods.where(kind: %w[year term]).find(period_id)
        from, to = period.start_on, period.end_on
      end
      raise ArgumentError, "Period exceeds project" if from < project.start_on ||
        (project.end_on && to > project.end_on)
      student = project.owner
      source = project.allocations.visible_to(student).where(entry_date: from..to)
      # Suppression eliminates trivially reversible small-cell aggregations.
      # The entire month is indivisible and parameters cannot filter accounts.
      enough_entries = source.distinct.limit(6).count(:entry_id) >= 5
      summary = enough_entries ? ProjectSummary.for_user(student, project.id,
        start_on: from.iso8601, end_on: to.iso8601,
        currency: project.currency) : nil
      result = {
        algorithm_version: VERSION, scope: "parent_project",
        project: { currency: project.currency,
          net_consumption: summary&.dig(:net_consumption),
          privacy_suppressed: !enough_entries,
          incomplete: summary ? summary[:incomplete] : false },
        start_on: from.iso8601, end_on: to.iso8601, currency: project.currency,
        data_at: Time.current.utc.iso8601(6),
        incomplete: summary ? summary[:incomplete] : false
      }
      if Grant.allowed?(parent, project, "budget_read")
        result[:budgets] = ParentOverview.budget_aggregate(project, student)
      end
      if Grant.allowed?(parent, project, "fees_read")
        result[:fees] = ParentOverview.fee_aggregate(project, student)
      end
      if Grant.allowed?(parent, project, "account_balance")
        result[:cash] = ParentOverview.cash_aggregate(project, student)
      end
      result[:funding] = ParentOverview.funding_aggregate(parent, project)
      result
    end

    class << self
      private
        def student_dates!(project:, period_id:, start_on:, end_on:)
          if period_id
            raise ArgumentError, "Cannot combine period and arbitrary dates" if start_on || end_on
            raise ArgumentError, "Project required for period" unless project
            raise ActiveRecord::RecordNotFound unless UuidFormat.valid?(period_id)
            period = project.periods.find(period_id)
            from, to = period.start_on, period.end_on
          else
            raise ArgumentError, "Both dates required" unless start_on && end_on
            from = Date.iso8601(start_on.to_s)
            to = Date.iso8601(end_on.to_s)
          end
          raise ArgumentError, "Invalid report interval" unless
            from.year.positive? && to >= from && to <= Date.current &&
            (to - from).to_i < 3660 &&
            (!project || (from >= project.start_on && (!project.end_on || to <= project.end_on)))
          [ from, to ]
        rescue Date::Error
          raise ArgumentError, "Invalid ISO report date"
        end

        def bounded!(scope)
          values = scope.limit(MAX_RECORDS + 1).to_a
          raise ArgumentError, "Report exceeds safe row limit" if values.size > MAX_RECORDS
          values
        end

        def authorized_cash_accounts!(user, project:, account_ids:)
          allowed = user.family.accounts.accessible_by(user)
            .where(accountable_type: "Depository", owner_id: user.id)
          allowed = allowed.where(id: ProjectAccount.where(
            project_id: project.id, family_id: project.family_id).select(:account_id)) if project
          if account_ids
            raise ArgumentError, "Expected unique account IDs" unless account_ids.is_a?(Array) &&
              account_ids.size.between?(1, 100) && account_ids.uniq.size == account_ids.size &&
              account_ids.all? { |id| UuidFormat.valid?(id) }
            allowed = allowed.where(id: account_ids)
          end
          accounts = bounded!(allowed.order(:id))
          raise ActiveRecord::RecordNotFound if account_ids && accounts.size != account_ids.size
          accounts
        end

        def cash_report!(user, from:, to:, currency:, account_ids:, accounts:, missing:)
          if account_ids.empty?
            return { gross_consumption: "0.0", refunds: "0.0",
              unallocated_inflows: "0.0", net_consumption: "0.0",
              sure_income_statement: nil, no_cash_accounts: true }
          end
          result = NetConsumption.for_user(user, start_on: from, end_on: to,
            currency: currency, account_ids: account_ids)
          if result[:incomplete]
            missing << { kind: "cash_fx", detail: "historical_rate_or_entry_missing" }
          end
          for_account = user.family.accounts.accessible_by(user).where(id: account_ids)
          sure = IncomeStatement.new(user.family, user: user, accounts: for_account)
            .totals_for(Period.custom(start_date: from, end_date: to), account_ids: account_ids)
          # Sure's original classification is not modified or summed into P4's
          # net personal cash consumption, which has debt-specific exclusions.
          result[:totals].merge(
            sure_income_statement: {
              income: sure.income_money.amount.to_s("F"),
              expense: sure.expense_money.amount.to_s("F"),
              transactions_count: sure.transactions_count
            },
            rates: result[:rates])
        end

        def convert!(amount, from:, to:, as_of:, missing:, kind:)
          quote = RateSnapshot.quote(from: from, to: to, date: as_of)
          if quote.missing?
            missing << { kind: kind, from_currency: from, to_currency: to }
            nil
          else
            quote.convert(amount).round(4)
          end
        end

        def debt_aggregate!(debts, currency:, date:, missing:)
          principal = ZERO
          outstanding = ZERO
          debts.each do |debt|
            if !debt.consistent?
              missing << { kind: "debt_evidence_changed" }
              next
            end
            amount = convert!(debt.principal_amount, from: debt.currency, to: currency,
              as_of: [ debt.incurred_on, date ].min, missing: missing, kind: "debt_fx")
            left = convert!(debt.outstanding_amount, from: debt.currency, to: currency,
              as_of: date, missing: missing, kind: "debt_fx")
            principal += amount if amount
            outstanding += left if left
          end
          ok = missing.none? { |m| %w[debt_fx debt_evidence_changed].include?(m[:kind]) }
          { principal_amount: ok ? principal.to_s("F") : nil,
            outstanding_amount: ok ? outstanding.to_s("F") : nil, count: debts.size }
        end

        def budgets!(user, project, from:, to:, currency:, missing:)
          budgets = bounded!(BudgetNode.for_user(user).where(
            project_id: project.id, status: "active", parent_id: nil)
            .where("start_on <= ? AND end_on >= ?", to, from).order(:id))
          planned = ZERO
          actual = ZERO
          budgets.each do |budget|
            data = budget.execution_for!(user)
            if data[:incomplete]
              missing << { kind: "budget_evidence" }
              next
            end
            amount = convert!(data[:limit_effective], from: budget.currency, to: currency,
              as_of: [ budget.start_on, Date.current ].min, missing: missing, kind: "budget_fx")
            used = convert!(data[:actual], from: budget.currency, to: currency,
              as_of: [ budget.start_on, Date.current ].min, missing: missing, kind: "budget_fx")
            planned += amount if amount
            actual += used if used
          end
          valid = missing.none? { |m| %w[budget_evidence budget_fx].include?(m[:kind]) }
          { limit_amount: valid ? planned.to_s("F") : nil,
            actual_amount: valid ? actual.to_s("F") : nil, count: budgets.size }
        end

        def fees!(user, project, currency:, date:, missing:)
          rows = bounded!(FeePlan.for_user(user).where(
            project_id: project.id, status: "active").order(:id))
          due = ZERO
          paid = ZERO
          remaining = ZERO
          rows.each do |fee|
            data = fee.payload_for(user)
            if data[:incomplete]
              missing << { kind: "fee_evidence" }
              next
            end
            [ [ :amount_due, due ], [ :paid_amount, paid ], [ :outstanding_amount, remaining ] ].each do |key, _|
              amount = convert!(fee.public_send(key), from: fee.currency, to: currency,
                as_of: date, missing: missing, kind: "fee_fx")
              case key
              when :amount_due then due += amount if amount
              when :paid_amount then paid += amount if amount
              when :outstanding_amount then remaining += amount if amount
              end
            end
          end
          valid = missing.none? { |m| %w[fee_evidence fee_fx].include?(m[:kind]) }
          { planned_amount: valid ? due.to_s("F") : nil,
            paid_amount: valid ? paid.to_s("F") : nil,
            outstanding_amount: valid ? remaining.to_s("F") : nil, count: rows.size }
        end

        def pools!(user, project, currency:, date:, missing:)
          pools = bounded!(FundPool.for_user(user).where(
            project_id: project.id, status: "active").order(:id))
          target = ZERO
          pools.each do |pool|
            next if pool.target_amount.nil?
            amount = convert!(pool.target_amount, from: pool.currency, to: currency,
              as_of: date, missing: missing, kind: "pool_fx")
            target += amount if amount
          end
          { target_not_cash: missing.any? { |m| m[:kind] == "pool_fx" } ? nil : target.to_s("F"),
            count: pools.size }
        end

        def funding!(user, project, currency:, date:, missing:)
          plans = bounded!(FundingPlan.for_student(user).where(
            project_id: project.id).order(:id))
          received = ZERO
          scheduled = ZERO
          plans.each do |plan|
            unless plan.evidence_consistent?
              missing << { kind: "funding_evidence_changed" }
              next
            end
            confirmed = convert!(plan.received_total, from: plan.currency, to: currency,
              as_of: date, missing: missing, kind: "funding_fx")
            expected = convert!(plan.outstanding_total, from: plan.currency, to: currency,
              as_of: date, missing: missing, kind: "funding_fx")
            received += confirmed if confirmed
            scheduled += expected if expected
          end
          valid = missing.none? { |m| %w[funding_evidence_changed funding_fx].include?(m[:kind]) }
          { already_received_not_new_cash: valid ? received.to_s("F") : nil,
            planned_unreceived_not_cash: valid ? scheduled.to_s("F") : nil, count: plans.size }
        end
    end
  end
end
