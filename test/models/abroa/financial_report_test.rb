require "test_helper"

class Abroa::FinancialReportTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @bank = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "GBP report bank", currency: "GBP", balance: 1500)
    @purchase = @bank.entries.create!(entryable: Transaction.new, name: "Shared purchase",
      amount: 800, currency: "GBP", date: Date.new(2025, 2, 10))
  end

  test "personal cash report conserves 800 cash, 200 expense, 600 claim and no income on recovery" do
    debt = Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "paid_for_other", contact_nickname: "Alex",
        source_entry_id: @purchase.id, currency: "GBP",
        personal_amount: "200", other_amount: "600", incurred_on: "2025-02-10" },
      key: "financial-report-debt")
    reimbursement = @bank.entries.create!(entryable: Transaction.new,
      name: "200 refunded", amount: -200, currency: "GBP", date: Date.new(2025, 2, 12))
    Abroa::DebtSettlement.settle_for!(@student, debt.id, entry_id: reimbursement.id,
      amount: "200", key: "financial-report-settlement")
    report = Abroa::FinancialReport.for_student!(@student, scope: "personal",
      start_on: "2025-02-01", end_on: "2025-02-28", currency: "GBP",
      account_ids: [ @bank.id ])
    assert_equal "200.0", report.dig(:cash_flow, :net_consumption)
    assert_equal "0.0", report.dig(:cash_flow, :unallocated_inflows)
    assert_equal "800.0", report.dig(:cash_flow, :gross_consumption)
    assert_equal "600.0", report.dig(:receivables, :principal_amount)
    assert_equal "400.0", report.dig(:receivables, :outstanding_amount)
    assert_equal false, report[:incomplete]
    assert_equal BigDecimal("1500"), @bank.reload.balance
  end

  test "project report reconciles allocated Sure entries with third-party share without adding fee commitments to cash" do
    project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Overseas degree", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "financial-report-project")
    Abroa::ProjectAccount.attach_for!(@student, project.id, @bank.id)
    Abroa::EntryAllocation.allocate_for!(@student, project.id,
      entry_id: @purchase.id, amount: "800", key: "project-entry")
    Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "paid_for_other", contact_nickname: "Shared budget",
        project_id: project.id, source_entry_id: @purchase.id,
        currency: "GBP", personal_amount: "200", other_amount: "600",
        incurred_on: "2025-02-10" }, key: "project-debt")
    Abroa::BudgetNode.create_for!(@student, project.id, attributes: {
      name: "Food budget", currency: "GBP", limit_amount: "1000",
      start_on: "2025-02-01", end_on: "2025-02-28"
    }, key: "project-budget")
    fee = Abroa::FeePlan.create_for!(@student, project.id, attributes: {
      name: "Next semester fee", kind: "tuition", currency: "GBP",
      gross_amount: "300", discount_amount: "0"
    }, key: "project-fee")
    Abroa::FeeInstallment.schedule_for!(@student, fee.id, attributes: {
      name: "Tuition", due_on: "2025-03-01", gross_amount: "300",
      discount_amount: "0", state: "confirmed"
    }, key: "project-fee-installment")
    year = Abroa::StudyPeriod.create_for!(@student, project.id,
      attributes: { name: "Year one", kind: "year",
        start_on: "2025-01-01", end_on: "2025-12-31" })
    term = Abroa::StudyPeriod.create_for!(@student, project.id,
      attributes: { name: "Term one", kind: "term", parent_id: year.id,
        start_on: "2025-02-01", end_on: "2025-05-31" })
    report = Abroa::FinancialReport.for_student!(@student, scope: "project",
      project_id: project.id, period_id: term.id, currency: "GBP")
    assert_equal term.start_on.iso8601, report[:start_on]
    assert_equal "800.0", report.dig(:project, :ledger_allocated_consumption)
    assert_equal "200.0", report.dig(:project, :personal_allocated_consumption)
    assert_equal "300.0", report.dig(:fees, :outstanding_amount)
    assert_equal "1000.0", report.dig(:budgets, :limit_amount)
    assert_equal false, report[:incomplete]
    assert_equal 2, project.periods.count
  end

  test "project report subtracts the correct third-party share of merchant refund and repayments" do
    project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Project with returns", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "project-refund-report")
    Abroa::ProjectAccount.attach_for!(@student, project.id, @bank.id)
    Abroa::EntryAllocation.allocate_for!(@student, project.id,
      entry_id: @purchase.id, amount: "800", key: "expense-800")
    debt = Abroa::PersonalDebt.create_for!(@student,
      attributes: { kind: "paid_for_other", contact_nickname: "Peer",
        project_id: project.id, source_entry_id: @purchase.id,
        currency: "GBP", personal_amount: "200", other_amount: "600",
        incurred_on: "2025-02-10" }, key: "project-refund-debt")
    refunded_entry = @bank.entries.create!(entryable: Transaction.new,
      name: "Merchant refund", amount: -400, currency: "GBP", date: Date.new(2025, 2, 12))
    link = Abroa::RefundLink.link_for!(@student, original_entry_id: @purchase.id,
      refund_entry_id: refunded_entry.id, applied_amount: "400", refund_amount: "400")
    Abroa::DebtSettlement.merchant_refund_for!(@student, debt.id,
      refund_link_id: link.id, key: "project-merchant-refund")
    Abroa::EntryAllocation.allocate_for!(@student, project.id,
      entry_id: refunded_entry.id, amount: "400", key: "project-refund-allocation")
    report = Abroa::FinancialReport.for_student!(@student, scope: "project",
      project_id: project.id, start_on: "2025-02-01", end_on: "2025-02-28", currency: "GBP")
    assert_equal "400.0", report.dig(:project, :ledger_allocated_consumption)
    assert_equal "100.0", report.dig(:project, :personal_allocated_consumption)

    repaid = @bank.entries.create!(entryable: Transaction.new,
      name: "Peer repaid", amount: -200, currency: "GBP", date: Date.new(2025, 2, 14))
    Abroa::DebtSettlement.settle_for!(@student, debt.id, entry_id: repaid.id,
      amount: "200", key: "project-peer-repaid")
    Abroa::EntryAllocation.allocate_for!(@student, project.id,
      entry_id: repaid.id, amount: "200", key: "project-repaid-allocation")
    report = Abroa::FinancialReport.for_student!(@student, scope: "project",
      project_id: project.id, start_on: "2025-02-01", end_on: "2025-02-28", currency: "GBP")
    assert_equal "200.0", report.dig(:project, :ledger_allocated_consumption)
    assert_equal "100.0", report.dig(:project, :personal_allocated_consumption)
    assert_equal "100.0", report.dig(:receivables, :outstanding_amount)
  end

  test "report returns missing FX evidence and null aggregates instead of combining currencies" do
    report = Abroa::FinancialReport.for_student!(@student, scope: "personal",
      start_on: "2025-02-01", end_on: "2025-02-28", currency: "EUR",
      account_ids: [ @bank.id ])
    assert_equal true, report[:incomplete]
    assert_nil report.dig(:cash_flow, :net_consumption)
    assert_includes report[:missing].map { |reason| reason[:kind] }, "cash_fx"
  end

  test "parent aggregate hides small private activity and refuses arbitrary windows or revoked Grant" do
    parent = users(:empty)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: parent, student_enabled: false, parent_enabled: true)
    project = Abroa::StudyProject.create_for!(@student,
      attributes: { name: "Private project", country: "GB", currency: "GBP",
        timezone: "Europe/London", start_on: "2025-01-01", end_on: "2028-12-31" },
      key: "report-parent-project")
    Abroa::ProjectAccount.attach_for!(@student, project.id, @bank.id)
    Abroa::EntryAllocation.allocate_for!(@student, project.id,
      entry_id: @purchase.id, amount: "800", key: "parent-visible-entry")
    _invite, token = Abroa::RelationshipInvite.issue_for!(parent,
      recipient_email: @student.email, recipient_role: "student", key: "report-parent-invite")
    relation = Abroa::RelationshipInvite.accept_for!(@student, token: token)
    grant = Abroa::Grant.create_for!(@student, relation.id, project_id: project.id,
      capability: "summary", key: "parent-report-summary")
    report = Abroa::FinancialReport.for_parent!(parent, project_id: project.id, month: "2025-02")
    assert_nil report.dig(:project, :net_consumption)
    assert_equal true, report.dig(:project, :privacy_suppressed)
    assert_not_includes report.to_json, @purchase.id
    assert_not_includes report.to_json, @bank.id
    assert_raises(ArgumentError) do
      Abroa::FinancialReport.for_parent!(parent, project_id: project.id,
        start_on: "2025-02-01", end_on: "2025-02-02")
    end
    Abroa::Grant.revoke_for!(@student, relation.id, grant.id, version: grant.lock_version)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::FinancialReport.for_parent!(parent, project_id: project.id, month: "2025-02")
    end
  end
end
