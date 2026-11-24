require "test_helper"

class Abroa::FeeAdjustmentTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fee deductions", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "fee-deductions")
    @plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "School tuition", kind: "tuition", currency: "GBP",
      gross_amount: "1000", discount_amount: "0" }, key: "fee-adjust-plan")
  end

  test "waiver scholarship offset and surcharge affect liability without phantom income" do
    assert_no_difference "Entry.count" do
      waiver = Abroa::FeeAdjustment.apply_for!(@user, @plan.id,
        kind: "waiver", amount: "100", reason: "Academic waiver", key: "waiver")
      assert_equal waiver.id, Abroa::FeeAdjustment.apply_for!(@user, @plan.id,
        kind: "waiver", amount: "100", reason: "Academic waiver", key: "waiver").id
      Abroa::FeeAdjustment.apply_for!(@user, @plan.id,
        kind: "scholarship_offset", amount: "200", reason: "Direct fee offset", key: "scholarship")
      Abroa::FeeAdjustment.apply_for!(@user, @plan.id,
        kind: "surcharge", amount: "50", reason: "Approved amendment", key: "surcharge")
    end
    assert_equal BigDecimal("750"), @plan.reload.amount_due
    assert_equal BigDecimal("750"), @plan.outstanding_amount
    assert_raises(Abroa::FeeAdjustment::Conflict) do
      Abroa::FeeAdjustment.apply_for!(@user, @plan.id,
        kind: "waiver", amount: "200", reason: "Changed request", key: "waiver")
    end
    assert_raises(ArgumentError) do
      Abroa::FeeAdjustment.apply_for!(@user, @plan.id,
        kind: "scholarship_cash", amount: "100", reason: "Not a fee discount", key: "cash")
    end
  end

  test "installment waiver changes both installment net due and plan total exactly once" do
    due = Abroa::FeeInstallment.schedule_for!(@user, @plan.id, attributes: {
      name: "First term", due_on: "2026-10-01",
      gross_amount: "1000", discount_amount: "0" }, key: "first-term")
    Abroa::FeeAdjustment.apply_for!(@user, @plan.id, installment_id: due.id,
      kind: "waiver", amount: "100", reason: "Partial waiver", key: "per-term-waiver")
    assert_equal BigDecimal("900"), due.reload.net_amount
    assert_equal BigDecimal("900"), @plan.reload.amount_due
    assert_equal BigDecimal("900"), due.outstanding_amount
    assert_equal BigDecimal("900"), @plan.outstanding_amount
    assert_equal BigDecimal("0"), Abroa::FeeSettlement.count
  end

  test "deductions cannot lower obligations below confirmed payments" do
    due = Abroa::FeeInstallment.schedule_for!(@user, @plan.id, attributes: {
      name: "First term", due_on: "2026-10-01",
      gross_amount: "1000", discount_amount: "0" }, key: "first-term")
    account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Fee settlement", currency: "GBP", balance: 1000)
    entry = account.entries.create!(entryable: Transaction.new, name: "Paid tuition",
      currency: "GBP", amount: 950, date: Date.new(2026, 9, 1))
    allocation = Abroa::EntryAllocation.allocate_for!(@user, @project.id,
      entry_id: entry.id, amount: "950", key: "fee-adjust-payment")
    Abroa::FeeSettlement.pay_for!(@user, due.id, allocation_id: allocation.id,
      amount: "950", key: "pay-fee")
    assert_raises(Abroa::FeeAdjustment::Conflict) do
      Abroa::FeeAdjustment.apply_for!(@user, @plan.id, installment_id: due.id,
        kind: "waiver", amount: "100", reason: "Would go under paid", key: "overwaive")
    end
    assert_equal BigDecimal("1000"), @plan.reload.amount_due
    assert_equal BigDecimal("950"), due.reload.paid_amount
  end
end
