require "test_helper"

class Abroa::FeePlanTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fee study", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2026-12-31" }, key: "fees-project")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Fee money", currency: "GBP", balance: 20000)
  end

  def create_plan(kind: "tuition", gross: "10000", discount: "2000", pool_id: nil)
    Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "School costs", kind: kind, currency: "GBP", gross_amount: gross,
      discount_amount: discount, fund_pool_id: pool_id }, key: "fee-#{kind}-#{gross}")
  end

  def create_installment(plan, name: "Term 1", gross: "5000", discount: "1000", due: "2025-09-01")
    Abroa::FeeInstallment.schedule_for!(@user, plan.id, attributes: {
      name: name, gross_amount: gross, discount_amount: discount, due_on: due }, key: name)
  end

  def posted_allocation(amount, date: Date.new(2025, 8, 10), name: "School payment")
    entry = @account.entries.create!(entryable: Transaction.new, name: name,
      amount: amount, currency: "GBP", date: date)
    allocation = Abroa::EntryAllocation.allocate_for!(@user, @project.id,
      entry_id: entry.id, amount: amount.to_s, key: "payment-#{entry.id}")
    [ entry, allocation ]
  end

  test "tuition installments and direct scholarship reduction do not create cash receipts" do
    plan = create_plan
    term_one = create_installment(plan)
    term_two = create_installment(plan, name: "Term 2", due: "2026-02-01")
    assert_equal BigDecimal("8000"), plan.amount_due
    assert_equal BigDecimal("4000"), term_one.net_amount
    assert_equal BigDecimal("4000"), term_two.net_amount
    assert_equal BigDecimal("0"), term_one.paid_amount
    entry, allocation = posted_allocation(3000)
    assert_no_difference "Entry.count" do
      Abroa::FeeSettlement.pay_for!(@user, term_one.id, allocation_id: allocation.id, amount: "3000", key: "tuition-paid")
    end
    assert_equal BigDecimal("3000"), term_one.reload.paid_amount
    assert_equal BigDecimal("1000"), term_one.outstanding_amount
    assert_equal "partially_paid", term_one.payment_status
    assert_equal BigDecimal("5000"), plan.reload.outstanding_amount
    assert_equal BigDecimal("3000"), entry.reload.amount
  end

  test "same payment ledger portion cannot fund multiple installments" do
    plan = create_plan(kind: "visa", gross: "100", discount: "0")
    first = create_installment(plan, gross: "60", discount: "0")
    second = create_installment(plan, name: "Follow-up", gross: "40", discount: "0")
    entry, allocation = posted_allocation(100)
    one = Abroa::FeeSettlement.pay_for!(@user, first.id, allocation_id: allocation.id, amount: "60", key: "payment-a")
    assert_equal one.id, Abroa::FeeSettlement.pay_for!(@user, first.id,
      allocation_id: allocation.id, amount: "60", key: "payment-a").id
    assert_raises(ArgumentError) do
      Abroa::FeeSettlement.pay_for!(@user, second.id, allocation_id: allocation.id,
        amount: "50", key: "overpayment")
    end
    assert_equal BigDecimal("60"), Abroa::FeeSettlement.where(allocation_id: allocation.id).sum(:amount)
    assert_equal BigDecimal("100"), entry.reload.amount
  end

  test "refundable housing deposit is an asset not a budget expense" do
    plan = create_plan(kind: "deposit", gross: "1000", discount: "0")
    due = create_installment(plan, gross: "1000", discount: "0")
    budget = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: {
      name: "Housing", currency: "GBP", start_on: "2025-01-01",
      end_on: "2025-12-31", limit_amount: "5000" })
    entry, allocation = posted_allocation(1000)
    Abroa::FeeSettlement.pay_for!(@user, due.id, allocation_id: allocation.id,
      amount: "1000", key: "deposit-paid")
    assert_equal BigDecimal("0"), budget.execution_for!(@user)[:actual]
    assert_equal BigDecimal("1000"), due.paid_amount
    assert_equal BigDecimal("1000"), entry.reload.amount
  end

  test "linked refund reopens amount due and keeps expense only once" do
    plan = create_plan(kind: "insurance", gross: "3000", discount: "0")
    due = create_installment(plan, gross: "3000", discount: "0")
    entry, allocation = posted_allocation(3000)
    Abroa::FeeSettlement.pay_for!(@user, due.id, allocation_id: allocation.id,
      amount: "3000", key: "insurance-paid")
    refund = @account.entries.create!(entryable: Transaction.new, name: "Policy refund",
      amount: -500, currency: "GBP", date: Date.new(2025, 9, 1))
    link = Abroa::RefundLink.link_for!(@user, original_entry_id: entry.id,
      refund_entry_id: refund.id, applied_amount: "500", refund_amount: "500")
    Abroa::FeeSettlement.refund_for!(@user, due.id, refund_link_id: link.id, amount: "500", key: "refund-one")
    assert_equal BigDecimal("2500"), due.reload.paid_amount
    assert_equal BigDecimal("500"), due.outstanding_amount
    assert_equal BigDecimal("3000"), entry.reload.amount
    assert_equal BigDecimal("-500"), refund.reload.amount
  end

  test "future fee commitment is separate from spent budget" do
    plan = create_plan(kind: "rent", gross: "1200", discount: "0")
    create_installment(plan, gross: "1200", discount: "0")
    budget = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: {
      name: "Living", currency: "GBP", start_on: "2025-01-01",
      end_on: "2025-12-31", limit_amount: "2000" })
    report = budget.execution_for!(@user)
    assert_equal BigDecimal("0"), report[:actual]
    assert_equal BigDecimal("1200"), report[:committed]
    assert_equal BigDecimal("800"), report[:uncommitted_remaining]
  end

  test "a confirmed fee cannot be cancelled after payment and a stale version cannot edit" do
    plan = create_plan(kind: "exam", gross: "100", discount: "0")
    due = create_installment(plan, gross: "100", discount: "0")
    entry, allocation = posted_allocation(50)
    Abroa::FeeSettlement.pay_for!(@user, due.id, allocation_id: allocation.id, amount: "50", key: "exam-half")
    assert_raises(Abroa::FeePlan::Conflict) do
      Abroa::FeeInstallment.change_for!(@user, due.id, version: 0, attributes: { state: "cancelled" })
    end
    assert_raises(Abroa::FeePlan::Conflict) do
      Abroa::FeeInstallment.change_for!(@user, due.id, version: -1, attributes: { due_on: "2025-10-01" })
    end
  end

  test "linked fund pool releases reserved money on payment and restores credit on refund" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Tuition source", kind: "tuition", currency: "GBP" }, key: "fee-fund")
    plan = create_plan(kind: "tuition", gross: "4000", discount: "0", pool_id: pool.id)
    due = create_installment(plan, gross: "4000", discount: "0")
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "6000", key: "fund")
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "reserve", amount: "4000", fee_installment_id: due.id, key: "reserve")
    original, allocation = posted_allocation(3000)
    @account.update!(balance: 17_000)
    assert_no_difference "Entry.count" do
      first = Abroa::FeeSettlement.pay_for!(@user, due.id,
        allocation_id: allocation.id, amount: "3000", key: "pay-with-reserve")
      assert_equal first.id, Abroa::FeeSettlement.pay_for!(@user, due.id,
        allocation_id: allocation.id, amount: "3000", key: "pay-with-reserve").id
    end
    assert_equal BigDecimal("3000"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("1000"), pool.native_reserved_for(@account)
    assert_equal BigDecimal("1000"), due.reload.outstanding_amount
    assert_equal 1, Abroa::PoolMovement.where(pool_id: pool.id, kind: "consume").count
    refund = @account.entries.create!(entryable: Transaction.new, name: "Tuition refund",
      amount: -500, currency: "GBP", date: Date.new(2025, 9, 1))
    link = Abroa::RefundLink.link_for!(@user, original_entry_id: original.id,
      refund_entry_id: refund.id, applied_amount: "500", refund_amount: "500")
    @account.update!(balance: 17_500)
    Abroa::FeeSettlement.refund_for!(@user, due.id, refund_link_id: link.id,
      amount: "500", key: "restore-refund")
    assert_equal BigDecimal("3500"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("1000"), pool.native_reserved_for(@account)
    assert_equal BigDecimal("1500"), due.reload.outstanding_amount
    assert_equal BigDecimal("3000"), original.reload.amount
    assert_equal BigDecimal("-500"), refund.reload.amount
  end

  test "cancelling unpaid fee releases its pool reservation without touching bank cash" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Cancellation fund", kind: "tuition", currency: "GBP" }, key: "cancel-fund")
    plan = create_plan(kind: "tuition", gross: "4000", discount: "0", pool_id: pool.id)
    due = create_installment(plan, gross: "4000", discount: "0")
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "5000", key: "allocate-cancel")
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "reserve", amount: "4000", fee_installment_id: due.id, key: "reserve-cancel")
    assert_equal BigDecimal("4000"), pool.native_reserved_for(@account)
    assert_no_difference "Entry.count" do
      Abroa::FeePlan.cancel_for!(@user, plan.id, version: plan.lock_version)
    end
    assert_equal "cancelled", plan.reload.status
    assert_equal "cancelled", due.reload.state
    assert_equal BigDecimal("0"), pool.native_reserved_for(@account)
    assert_equal BigDecimal("5000"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("20000"), @account.reload.balance
    assert_equal 1, pool.movements.where(kind: "unreserve", fee_installment_id: due.id).count
  end

  test "fee settlement can use one Sure Goal-backed pool without double reservation or posting" do
    goal = @user.family.goals.create!(name: "Tuition savings", target_amount: 5000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 5000) ])
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Goal-backed tuition", kind: "tuition", currency: "GBP", goal_id: goal.id })
    plan = create_plan(kind: "tuition", gross: "1000", discount: "0", pool_id: pool.id)
    due = create_installment(plan, gross: "1000", discount: "0")
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "reserve", amount: "1000", fee_installment_id: due.id, key: "goal-fee-reserve")
    entry, allocation = posted_allocation(1000)
    @account.update!(balance: 19_000)
    assert_no_difference "Entry.count" do
      first = Abroa::FeeSettlement.pay_for!(@user, due.id,
        allocation_id: allocation.id, amount: "1000", key: "goal-fee-pay")
      assert_equal first.id, Abroa::FeeSettlement.pay_for!(@user, due.id,
        allocation_id: allocation.id, amount: "1000", key: "goal-fee-pay").id
    end
    assert_equal BigDecimal("1000"), goal.reload.consumed_amount
    assert_equal BigDecimal("4000"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("0"), pool.native_reserved_for(@account)
    summary = Abroa::AllocationGuard.summary_for!(@user, @account.id)
    assert_equal BigDecimal("4000"), summary[:reserved_total]
    assert_equal BigDecimal("0"), summary[:pool_reserved]
    assert_equal BigDecimal("1000"), due.reload.paid_amount
    assert_equal BigDecimal("1000"), entry.reload.amount
  end

  test "fees cannot accept unposted transactions or unmatched cross-currency parity" do
    plan = create_plan(kind: "transport", gross: "100", discount: "0")
    due = create_installment(plan, gross: "100", discount: "0")
    entry, allocation = posted_allocation(100)
    entry.update!(currency: "USD")
    assert_raises(ArgumentError) do
      Abroa::FeeSettlement.pay_for!(@user, due.id, allocation_id: allocation.id, amount: "100", key: "fake-rate")
    end
  end
end
