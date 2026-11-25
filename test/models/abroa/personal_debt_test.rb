require "test_helper"

class Abroa::PersonalDebtTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @outsider = users(:empty)
    @bank = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "GBP bank for debts", currency: "GBP", balance: 2_000)
    @purchase = posted(800, name: "Shared meal")
  end

  test "800 paid with 200 own consumption leaves 600 claim and partial recovery is not income" do
    before_cash = @bank.balance
    debt = paid_for_other
    assert_equal "receivable", debt.direction
    assert_equal BigDecimal("600"), debt.outstanding_amount
    assert_equal "OtherAsset", debt.debt_account.accountable_type
    assert_equal before_cash, @bank.reload.balance

    receipt = posted(-200, name: "Alex repaid")
    settlement = Abroa::DebtSettlement.settle_for!(@student, debt.id,
      entry_id: receipt.id, amount: "200", key: "partial-200")
    assert settlement.consistent?
    assert_equal "partially_settled", debt.reload.status
    assert_equal BigDecimal("400"), debt.outstanding_amount
    assert_equal settlement.id, Abroa::DebtSettlement.settle_for!(@student, debt.id,
      entry_id: receipt.id, amount: "200", key: "partial-200").id

    statement = Abroa::NetConsumption.for_user(@student,
      start_on: Date.new(2025, 2, 1), end_on: Date.new(2025, 2, 28), currency: "GBP",
      account_ids: [ @bank.id ])
    assert_equal "200.0", statement[:totals][:net_consumption]
    assert_equal "0.0", statement[:totals][:unallocated_inflows]
    assert_equal before_cash, @bank.reload.balance
  end

  test "externally paid personal expense is booked as payable and repaying it is not a second expense" do
    paid_for_other
    debt = Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "paid_by_other", contact_nickname: "Jamie", purpose: "Books",
        currency: "GBP", personal_amount: "200", other_amount: "0",
        incurred_on: "2025-02-10" }, key: "payable-200")
    assert_equal "payable", debt.direction
    assert_equal "OtherLiability", debt.debt_account.accountable_type
    assert_equal BigDecimal("200"), debt.outstanding_amount
    settlement = Abroa::DebtSettlement.settle_for!(@student, debt.id,
      entry_id: posted(200, name: "Repaid Jamie").id, amount: "200", key: "repay-jamie")
    assert settlement.consistent?
    assert_equal BigDecimal("0"), debt.reload.outstanding_amount
    assert_equal "settled", debt.status
    statement = Abroa::NetConsumption.for_user(@student,
      start_on: Date.new(2025, 2, 1), end_on: Date.new(2025, 2, 28), currency: "GBP",
      account_ids: [ @bank.id ])
    assert_equal "1000.0", statement[:totals][:gross_consumption]
    assert_equal "400.0", statement[:totals][:net_consumption]
  end

  test "settlements retain historical exchange rates when provider rates change" do
    debt = paid_for_other
    usd = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "USD repayments", currency: "USD", balance: 1_000)
    rate = ExchangeRate.create!(from_currency: "USD", to_currency: "GBP",
      date: Date.new(2025, 2, 10), rate: BigDecimal("0.8"))
    receipt = usd.entries.create!(entryable: Transaction.new, name: "USD receipt",
      amount: -250, currency: "USD", date: Date.new(2025, 2, 10))
    item = Abroa::DebtSettlement.settle_for!(@student, debt.id,
      entry_id: receipt.id, amount: "250", key: "usd-payment")
    assert_equal BigDecimal("200"), item.applied_amount
    assert_equal BigDecimal("0.8"), item.rate_snapshot.rate
    rate.update!(rate: BigDecimal("0.9"))
    assert_equal BigDecimal("400"), debt.reload.outstanding_amount
  end

  test "duplicate and over-limit requests are rejected without changing authoritative entries" do
    debt = paid_for_other
    receipt = posted(-500)
    count = Entry.count
    Abroa::DebtSettlement.settle_for!(@student, debt.id, entry_id: receipt.id,
      amount: "200", key: "first")
    assert_raises(Abroa::DebtSettlement::Conflict) do
      Abroa::DebtSettlement.settle_for!(@student, debt.id, entry_id: receipt.id,
        amount: "300", key: "first")
    end
    assert_raises(Abroa::DebtSettlement::Conflict, ArgumentError) do
      Abroa::DebtSettlement.settle_for!(@student, debt.id, entry_id: receipt.id,
        amount: "500", key: "new-key")
    end
    assert_raises(Abroa::DebtSettlement::Conflict, ArgumentError) do
      Abroa::DebtSettlement.settle_for!(@student, debt.id,
        entry_id: posted(-500, name: "Over-limit").id, amount: "500", key: "over")
    end
    assert_equal BigDecimal("400"), debt.reload.outstanding_amount
    assert_equal count + 1, Entry.count
  end

  test "outsiders cannot read or alter obligations even if they know IDs" do
    debt = paid_for_other
    assert_raises(ActiveRecord::RecordNotFound) { Abroa::PersonalDebt.for_user(@outsider).find(debt.id) }
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::DebtSettlement.settle_for!(@outsider, debt.id,
        entry_id: posted(-20).id, amount: "20", key: "foreign")
    end
    assert_equal BigDecimal("600"), debt.reload.outstanding_amount
  end

  test "merchant purchase refund reduces third-party claim and personal consumption proportionally" do
    debt = paid_for_other
    merchant_return = posted(-400, name: "Purchase refunded")
    link = Abroa::RefundLink.link_for!(@student,
      original_entry_id: @purchase.id, refund_entry_id: merchant_return.id,
      applied_amount: "400", refund_amount: "400")
    claim_reduction = Abroa::DebtSettlement.merchant_refund_for!(@student, debt.id,
      refund_link_id: link.id, key: "merchant-refund-400")
    assert claim_reduction.consistent?
    assert_equal BigDecimal("300"), claim_reduction.applied_amount
    assert_equal BigDecimal("300"), debt.reload.outstanding_amount
    report = Abroa::NetConsumption.for_user(@student,
      start_on: Date.new(2025, 2, 1), end_on: Date.new(2025, 2, 28),
      currency: "GBP", account_ids: [ @bank.id ])
    assert_equal "100.0", report[:totals][:net_consumption]
    assert_equal "0.0", report[:totals][:unallocated_inflows]
    assert_equal claim_reduction.id, Abroa::DebtSettlement.merchant_refund_for!(@student, debt.id,
      refund_link_id: link.id, key: "merchant-refund-400").id
  end

  test "two receipts close debt, refund reopens only the repaid portion" do
    debt = paid_for_other
    first = Abroa::DebtSettlement.settle_for!(@student, debt.id,
      entry_id: posted(-400, name: "First reimbursement").id, amount: "400", key: "pay-400")
    second = Abroa::DebtSettlement.settle_for!(@student, debt.id,
      entry_id: posted(-200, name: "Second reimbursement").id, amount: "200", key: "pay-200")
    assert_equal "settled", debt.reload.status
    assert_equal BigDecimal("0"), debt.outstanding_amount
    assert first.consistent?
    assert second.consistent?
    returned = posted(50, name: "Returned reimbursement")
    refund = Abroa::DebtSettlement.refund_for!(@student, debt.id,
      entry_id: returned.id, amount: "50",
      refunded_settlement_id: second.id, key: "refund-50")
    assert refund.consistent?
    assert_equal "partially_settled", debt.reload.status
    assert_equal BigDecimal("50"), debt.outstanding_amount
    assert_equal refund.id, Abroa::DebtSettlement.refund_for!(@student, debt.id,
      entry_id: returned.id, amount: "50",
      refunded_settlement_id: second.id, key: "refund-50").id
    assert_raises(Abroa::DebtSettlement::Conflict) do
      Abroa::DebtSettlement.refund_for!(@student, debt.id,
        entry_id: posted(200, name: "Excessive return").id, amount: "200",
        refunded_settlement_id: second.id, key: "over-refund")
    end
  end

  test "cancellation has an audit trail and refuses a subsequent settlement" do
    debt = paid_for_other
    assert_equal true, debt.consistent?
    count = Entry.where(account_id: @bank.id).count
    debt.cancel_for!(@student, version: debt.lock_version)
    assert_equal "cancelled", debt.reload.status
    assert_equal BigDecimal("0"), debt.outstanding_amount
    assert_equal 0, debt.debt_account.entries.where(entryable_type: "Valuation").order(:date).last.amount
    assert_equal count, Entry.where(account_id: @bank.id).count
    assert_raises(Abroa::DebtSettlement::Conflict) do
      Abroa::DebtSettlement.settle_for!(@student, debt.id,
        entry_id: posted(-10).id, amount: "10", key: "late-after-cancel")
    end
    assert Abroa::PlanningAuditEvent.where(event_type: "personal_debt.cancelled", resource_id: debt.id).exists?
  end

  test "borrowed cash is not income and lending is not personal expense" do
    loan_out = posted(120, name: "Lent to friend")
    lent = Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "lent", contact_nickname: "Friend", currency: "GBP",
        source_entry_id: loan_out.id, personal_amount: "0", other_amount: "120",
        incurred_on: "2025-02-10" }, key: "lent-120")
    incoming = posted(-90, name: "Borrowed from friend")
    borrowed = Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "borrowed", contact_nickname: "Another friend", currency: "GBP",
        source_entry_id: incoming.id, personal_amount: "0", other_amount: "90",
        incurred_on: "2025-02-10" }, key: "borrowed-90")
    assert_equal BigDecimal("120"), lent.outstanding_amount
    assert_equal BigDecimal("90"), borrowed.outstanding_amount
    report = Abroa::NetConsumption.for_user(@student,
      start_on: Date.new(2025, 2, 1), end_on: Date.new(2025, 2, 28),
      currency: "GBP", account_ids: [ @bank.id ])
    assert_equal "800.0", report[:totals][:net_consumption]
    assert_equal "0.0", report[:totals][:unallocated_inflows]
  end

  private
    def paid_for_other
      Abroa::PersonalDebt.create_for!(@student,
        attributes: { kind: "paid_for_other", contact_nickname: "Alex", purpose: "Shared meal",
          source_entry_id: @purchase.id, currency: "GBP", personal_amount: "200",
          other_amount: "600", incurred_on: "2025-02-10", due_on: "2025-03-01" }, key: "paid-800")
    end

    def posted(amount, name: "Payment")
      @bank.entries.create!(entryable: Transaction.new, name: name,
        amount: amount, currency: "GBP", date: Date.new(2025, 2, 10))
    end
end
