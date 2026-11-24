require "test_helper"
require "json"

class AbroaCoreCompatibilityTest < ActiveSupport::TestCase
  include EntriesTestHelper

  CASES = JSON.parse(Rails.root.join("test/fixtures/files/abroa/golden_core_cases.json").read).freeze

  setup do
    @family = families(:dylan_family)
    @currency = @family.currency
    @account = Account.create!(
      family: @family, accountable: Depository.new,
      name: "Abroa golden account", currency: @currency, balance: 1_000
    )
    @day = Date.current
  end

  test "split payment is reported once and its children cannot settle another bill" do
    fixture = CASES.fetch("split_bill")
    parent = transaction(fixture.fetch("charge"), "Combined rent charge")
    parts = fixture.fetch("parts").map do |part|
      { name: part.fetch("name"), amount: part.fetch("amount").to_d }
    end

    assert parent.split_once!(parts)
    assert_not parent.reload.split_once!(parts)
    children = parent.child_entries.to_a
    assert_equal fixture.fetch("reported_expense").to_d, report_total([ parent, *children ], "expense")

    series = @family.recurring_transactions.create!(
      account: @account, name: "Combined rent", amount: fixture.fetch("charge").to_d,
      currency: @currency, expected_day_of_month: 29,
      last_occurrence_date: @day, next_expected_date: 1.month.from_now.to_date,
      status: "active", manual: true
    )
    due_on = (Date.current + 1.month).beginning_of_month + 9
    occurrence = series.recurring_occurrences.order(:due_on).last ||
      series.recurring_occurrences.create!(
        family: @family, original_due_on: due_on, due_on: due_on, currency: @currency
      )

    allocator = RecurringTransaction::Allocator.new(occurrence)
    payment = allocator.allocate!(entry: parent, amount: fixture.fetch("charge").to_d)
    assert_equal fixture.fetch("charge").to_d, payment.allocated_amount
    assert_equal fixture.fetch("remaining_due").to_d, occurrence.reload.remaining_amount
    remaining = RecurringTransaction::Allocator.remaining_by_entry(children)
    children.each { |child| assert_equal 0, remaining.fetch(child.id) }
  end

  test "refund preserves both signed entries and the net cost is reproducible" do
    fixture = CASES.fetch("refund")
    purchase = transaction(fixture.fetch("purchase"), "Course materials")
    refund = transaction(-fixture.fetch("refund").to_d, "Refund of course materials")
    records = [ purchase, refund ]

    assert_equal fixture.fetch("purchase").to_d, report_total(records, "expense")
    assert_equal fixture.fetch("refund").to_d, report_total(records, "income")
    assert_equal fixture.fetch("net_cost").to_d,
      report_total(records, "expense") - report_total(records, "income")
    assert_equal fixture.fetch("net_cost").to_d, Entry.where(id: records.map(&:id)).sum(:amount)
  end

  test "credit card payment is an internal transfer and does not double count spending" do
    fixture = CASES.fetch("credit_card_payment")
    transfer = Transfer::Creator.new(
      family: @family,
      source_account_id: accounts(:depository).id,
      destination_account_id: accounts(:credit_card).id,
      date: @day, amount: fixture.fetch("amount").to_d,
      idempotency_key: SecureRandom.uuid
    ).create

    outflow = transfer.outflow_transaction
    inflow = transfer.inflow_transaction
    assert_equal "cc_payment", outflow.kind
    assert_equal "funds_movement", inflow.kind
    assert_equal fixture.fetch("amount").to_d, outflow.entry.amount
    assert_equal(-fixture.fetch("amount").to_d, inflow.entry.amount)
    assert_equal fixture.fetch("reported_expense").to_d,
      report_total([ outflow.entry, inflow.entry ], "expense")
  end

  test "goal consumption releases its earmark without creating another bank transaction" do
    fixture = CASES.fetch("goal_consume")
    assert_equal fixture.fetch("account_balance").to_d, @account.balance
    goal = @family.goals.create!(
      name: "Tuition reserve", target_amount: fixture.fetch("target").to_d, currency: @currency,
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: fixture.fetch("initial_allocation").to_d) ]
    )

    assert_no_difference -> { @account.entries.count } do
      goal.consume!(fixture.fetch("consumed").to_d)
    end
    assert_equal fixture.fetch("consumed").to_d, goal.reload.consumed_amount_money.amount
    assert_equal fixture.fetch("remaining_allocation").to_d, goal.goal_accounts.first.allocated_amount
    assert_equal fixture.fetch("account_balance").to_d, @account.reload.balance
  end

  private
    def transaction(amount, name)
      create_transaction(
        account: @account, date: @day, currency: @currency, name: name,
        amount: amount.to_d, category: categories(:food_and_drink)
      )
    end

    def report_total(entries, classification)
      rows = IncomeStatement::Totals.new(
        @family,
        transactions_scope: Transaction.where(id: entries.map(&:entryable_id)),
        date_range: @day..@day,
        include_trades: false,
        included_account_ids: entries.map(&:account_id).uniq
      ).call
      rows.select { |row| row.classification == classification }.sum(&:total).to_d
    end
end
