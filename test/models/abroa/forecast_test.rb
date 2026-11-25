require "test_helper"

class Abroa::ForecastTest < ActiveSupport::TestCase
  BASE_DATE = Date.new(2026, 11, 25)

  test "A11 standard calculation: day ten 500, day thirty 100, negative day thirty six" do
    result = Abroa::Forecast.simulate(
      opening_balance: "1000", daily_consumption: "20", currency: "GBP",
      as_of: BASE_DATE, fixed_events: [ { day: 10, amount: "300", label: "Housing fee" } ])
    assert_equal "500.0", result[:balances][:day_10]
    assert_equal "100.0", result[:balances][:day_30]
    assert_equal (BASE_DATE + 36).iso8601, result[:first_shortage_on]
    assert_equal "20.0", result[:first_shortage_amount]
    assert_equal 35, result[:runway_days]
    assert_equal "-1100.0", result[:balances][:day_90]
    assert_equal "-2900.0", result[:balances][:day_180]
  end

  test "conservative excludes scheduled but unreceived parental support" do
    base = { opening_balance: "1000", daily_consumption: "20", as_of: BASE_DATE,
      currency: "GBP", planned_events: [ { day: 10, amount: "600", label: "Unconfirmed allowance" } ] }
    conservative = Abroa::Forecast.simulate(**base, scenario: "conservative")
    planned = Abroa::Forecast.simulate(**base, scenario: "planned_funding")
    assert_equal "400.0", conservative[:balances][:day_30]
    assert_equal "1000.0", planned[:balances][:day_30]
    assert_equal "0.0", conservative[:assumed_future_income]
    assert_equal "600.0", planned[:assumed_future_income]
  end

  test "stress and late funding reduce coverage without updating actual ledger" do
    args = { opening_balance: "1000", daily_consumption: "10", as_of: BASE_DATE, currency: "GBP",
      fixed_events: [ { day: 5, amount: "200", label: "Rent" } ],
      planned_events: [ { day: 8, amount: "200", label: "Allowance" } ] }
    normal = Abroa::Forecast.simulate(**args, scenario: "planned_funding")
    late = Abroa::Forecast.simulate(**args, scenario: "planned_funding",
      funding_delay_days: 30, living_multiplier: "1.25")
    assert_operator BigDecimal(normal[:balances][:day_30]), :>, BigDecimal(late[:balances][:day_30])
    stress = Abroa::Forecast.simulate(**args, scenario: "stress")
    assert_operator BigDecimal(stress[:balances][:day_30]), :<, BigDecimal(normal[:balances][:day_30])
  end

  test "zero spend never has shortage, negative opening reports immediate shortage" do
    empty = Abroa::Forecast.simulate(opening_balance: "0", daily_consumption: "0",
      currency: "GBP", as_of: BASE_DATE)
    assert_nil empty[:first_shortage_on]
    assert_nil empty[:runway_days]
    negative = Abroa::Forecast.simulate(opening_balance: "-1", daily_consumption: "0",
      currency: "GBP", as_of: BASE_DATE)
    assert_equal BASE_DATE.iso8601, negative[:first_shortage_on]
    assert_equal "1.0", negative[:first_shortage_amount]
    assert_equal 0, negative[:runway_days]
  end

  test "invalid multiplier and currency are rejected deterministically" do
    assert_raises(ArgumentError) do
      Abroa::Forecast.simulate(opening_balance: "100", daily_consumption: "1",
        currency: "GBP", as_of: BASE_DATE, living_multiplier: "-2")
    end
    assert_raises(ArgumentError) do
      Abroa::Forecast.simulate(opening_balance: "100", daily_consumption: "1",
        currency: "BADTOKEN", as_of: BASE_DATE)
    end
    assert_raises(ArgumentError) do
      Abroa::Forecast.simulate(opening_balance: "100", daily_consumption: "1",
        currency: "GBP", as_of: BASE_DATE, fixed_events: [ { day: 0, amount: "5" } ])
    end
  end

  test "FX shock applies to converted foreign-currency fees and funding, not local expenses" do
    input = { opening_balance: "1000", daily_consumption: "0", currency: "GBP",
      as_of: BASE_DATE, scenario: "planned_funding",
      fixed_events: [
        { day: 5, amount: "100", label: "Imported course", fx_exposed: true },
        { day: 5, amount: "200", label: "Local rent", rent_sensitive: true }
      ],
      planned_events: [ { day: 5, amount: "100", label: "Foreign allowance", fx_exposed: true } ] }
    standard = Abroa::Forecast.simulate(**input)
    shock = Abroa::Forecast.simulate(**input, fx_shock_pct: "0.1", rent_multiplier: "1.5")
    assert_equal "800.0", standard[:balances][:day_10]
    assert_equal "680.0", shock[:balances][:day_10]
    assert_equal "0.1", shock.dig(:assumptions, :fx_shock_pct)
  end

  test "student without cash or history has reproducible zero baseline, no false transactions" do
    user = users(:empty)
    count = Entry.count
    result = Abroa::Forecast.for_student(user, as_of: Date.current, currency: "GBP")
    assert_equal "0.0", result[:opening_balance]
    assert_equal "0.0", result[:daily_consumption]
    assert_nil result[:first_shortage_on]
    assert_equal 0, result[:cash_account_count]
    assert_includes result[:data_assumptions], "no_history_zero_consumption_baseline"
    assert_equal count, Entry.count
  end

  test "missing historical FX explicitly blocks numeric output instead of mixing currencies" do
    user = users(:family_admin)
    account = Account.create!(family: user.family, owner: user,
      accountable: Depository.new, name: "Unconverted NZD", currency: "NZD", balance: 1000)
    count = Entry.count
    result = Abroa::Forecast.for_student(user, as_of: Date.current,
      currency: "GBP", account_ids: [ account.id ])
    assert_equal true, result[:incomplete]
    assert_nil result.dig(:balances, :day_30)
    assert_includes result[:missing].map { |item| item[:kind] }, "cash_fx"
    assert_equal count, Entry.count
  end

  test "known fixed fee payments are removed from routine spending baseline" do
    user = users(:family_admin)
    project = Abroa::StudyProject.create_for!(user,
      attributes: { name: "Fixed expense projection", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "p4-fixed-projection")
    bank = Account.create!(family: user.family, owner: user,
      accountable: Depository.new, name: "History account", currency: "GBP", balance: 1000)
    Abroa::ProjectAccount.attach_for!(user, project.id, bank.id)
    30.times do |day|
      bank.entries.create!(entryable: Transaction.new, name: "Routine expense",
        amount: 20, currency: "GBP", date: Date.current - (day + 1))
    end
    fee = Abroa::FeePlan.create_for!(user, project.id,
      attributes: { name: "Next month rent", kind: "rent", currency: "GBP",
        gross_amount: "300", discount_amount: "0" }, key: "p4-fixed-fee")
    installment = Abroa::FeeInstallment.schedule_for!(user, fee.id,
      attributes: { name: "Future rent", due_on: (Date.current + 10).iso8601,
        gross_amount: "300", discount_amount: "0", state: "confirmed" }, key: "fixed-fee-installment")
    entry = bank.entries.create!(entryable: Transaction.new, name: "Deposit for rent",
      amount: 100, currency: "GBP", date: Date.current - 5)
    allocation = Abroa::EntryAllocation.allocate_for!(user, project.id,
      entry_id: entry.id, amount: "100", key: "fixed-fee-entry")
    Abroa::FeeSettlement.pay_for!(user, installment.id,
      allocation_id: allocation.id, amount: "100", key: "fixed-fee-paid")
    result = Abroa::Forecast.for_student(user, project_id: project.id,
      as_of: Date.current, currency: "GBP", account_ids: [ bank.id ])
    assert_equal "20.0", result[:daily_consumption]
    assert_equal "600.0", result.dig(:balances, :day_10)
    assert_operator BigDecimal(result[:estimated_study_total_cost]), :>, BigDecimal("0")
    assert_operator BigDecimal(result[:estimated_study_remaining_cost]), :>, BigDecimal("200")
    assert_equal BigDecimal("1000"), bank.reload.balance
  end

  test "student computation reads Sure bank balances and never creates bank entries" do
    user = users(:family_admin)
    bank = Account.create!(family: user.family, owner: user,
      accountable: Depository.new, name: "P4 forecast bank", currency: "GBP", balance: 1000)
    30.times do |day|
      bank.entries.create!(entryable: Transaction.new, name: "Actual daily spending",
        amount: 20, currency: "GBP", date: Date.current - (day + 1))
    end
    count = Entry.count
    result = Abroa::Forecast.for_student(user, as_of: Date.current,
      currency: "GBP", account_ids: [ bank.id ])
    assert_equal "GBP", result[:currency]
    assert_equal "1000.0", result[:opening_balance]
    assert_equal "20.0", result[:daily_consumption]
    assert result[:data_version].present?
    assert_equal count, Entry.count
    assert_equal BigDecimal("1000"), bank.reload.balance

    bank.entries.create!(entryable: Transaction.new, name: "Exceptional impulse purchase",
      amount: 500, currency: "GBP", date: Date.current - 1)
    spike = Abroa::Forecast.for_student(user, as_of: Date.current,
      currency: "GBP", account_ids: [ bank.id ])
    assert_not_equal result[:data_version], spike[:data_version]
    assert_includes spike[:anomalies].map { |item| item[:kind] }, "recent_spending_spike"
  end
end
