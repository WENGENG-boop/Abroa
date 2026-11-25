require "test_helper"

class Abroa::ParentOverviewTest < ActiveSupport::TestCase
  setup do
    @student = users(:family_admin)
    @parent = users(:empty)
    @outsider = users(:family_member)
    Abroa::Profile.create!(user: @student, student_enabled: true, parent_enabled: false)
    Abroa::Profile.create!(user: @parent, student_enabled: false, parent_enabled: true)
    _invite, token = Abroa::RelationshipInvite.issue_for!(@student,
      recipient_email: @parent.email, recipient_role: "parent", key: "parent-overview")
    @relation = Abroa::RelationshipInvite.accept_for!(@parent, token: token)
    @project = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "UK degree", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "overview-project")
    @hidden = Abroa::StudyProject.create_for!(@student, attributes: {
      name: "Private travel", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2025-12-31"
    }, key: "hidden-project")
    @account = Account.create!(family: @student.family, owner: @student,
      accountable: Depository.new, name: "Private account", currency: "GBP", balance: 1000)
    Abroa::ProjectAccount.attach_for!(@student, @project.id, @account.id)
    expense = @account.entries.create!(entryable: Transaction.new, name: "Private merchant",
      amount: 100, currency: "GBP", date: Date.new(2025, 3, 1))
    Abroa::EntryAllocation.allocate_for!(@student, @project.id,
      entry_id: expense.id, amount: "50", key: "expenses-50")
    @budget = Abroa::BudgetNode.create_for!(@student, @project.id, attributes: {
      name: "Tuition", start_on: "2025-01-01", end_on: "2025-12-31",
      currency: "GBP", limit_amount: "1000"
    }, key: "overview-budget")
    @fee = Abroa::FeePlan.create_for!(@student, @project.id, attributes: {
      name: "Tuition", kind: "tuition", currency: "GBP",
      gross_amount: "500", discount_amount: "50"
    }, key: "overview-fee")
    @pool = Abroa::FundPool.create_for!(@student, @project.id, attributes: {
      name: "Living", kind: "living", currency: "GBP", target_amount: "500"
    }, key: "overview-pool")
  end

  test "no grant and summary-only grant never expose private budget or account details" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ParentOverview.project_for!(@parent, @project.id)
    end
    grant(:summary)
    listing = Abroa::ParentOverview.projects_for(@parent)
    assert_equal [ @project.id ], listing.map { |p| p[:id] }
    summary = Abroa::ParentOverview.project_for!(@parent, @project.id)
    assert_equal "UK degree", summary.dig(:project, :name)
    assert_equal "50.0", summary.dig(:consumption, :net_amount)
    assert_nil summary[:budgets]
    assert_nil summary[:fees]
    assert_nil summary[:pools]
    assert_nil summary[:cash]
    assert_not_includes summary.to_json, @account.id
    assert_not_includes summary.to_json, "Private merchant"
    assert_not_includes summary.to_json, "Private account"
    assert_not_includes summary.to_json, @hidden.id
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ParentOverview.project_for!(@parent, @hidden.id)
    end
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ParentOverview.project_for!(@outsider, @project.id)
    end
  end

  test "project grants selectively unlock aggregates without raw transactions" do
    grant(:summary)
    grant(:budget_read)
    grant(:fees_read)
    grant(:account_balance)
    Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
      capability: "pool_manage", resource_kind: "fund_pool",
      resource_id: @pool.id, key: "overview-pool-grant")
    summary = Abroa::ParentOverview.project_for!(@parent, @project.id)
    assert_equal "1000.0", summary.dig(:budgets, :planned_amount)
    assert_equal "450.0", summary.dig(:fees, :outstanding_amount)
    assert_equal "500.0", summary.dig(:pools, :target_amount)
    assert_equal "1000.0", summary.dig(:cash, :balance)
    assert_not_includes summary.to_json, @account.id
    assert_not_includes summary.to_json, @budget.id
    assert_not_includes summary.to_json, @fee.id
    assert_not_includes summary.to_json, @pool.id
    assert_not_includes summary.to_json, @hidden.name
  end

  test "revoked or expired authorization eliminates summary access immediately" do
    summary_grant = grant(:summary)
    assert Abroa::ParentOverview.project_for!(@parent, @project.id)
    Abroa::Grant.revoke_for!(@student, @relation.id, summary_grant.id,
      version: summary_grant.lock_version)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ParentOverview.project_for!(@parent, @project.id)
    end
    newer = grant(:summary, key: "new-grant")
    newer.update!(expires_at: 1.second.ago)
    assert_raises(ActiveRecord::RecordNotFound) do
      Abroa::ParentOverview.project_for!(@parent, @project.id)
    end
  end

  test "funding receipts are not added to expense allocation or real bank cash" do
    grant(:summary)
    plan = Abroa::FundingPlan.create_for!(@parent, relationship_id: @relation.id,
      project_id: @project.id, attributes: {
        name: "Allowance", amount: "200", currency: "GBP",
        frequency: "once", scheduled_on: "2025-03-01"
      }, key: "overview-funding")
    plan = Abroa::FundingPlan.confirm_for!(@student, plan.id,
      version: plan.lock_version, destination_account_id: @account.id)
    entry = @account.entries.create!(entryable: Transaction.new,
      name: "Support wire", amount: -200, currency: "GBP", date: Date.new(2025, 3, 1))
    balance = @account.reload.balance
    Abroa::FundingReceipt.match_for!(@student, plan.id, entry_id: entry.id, key: "overview-match")
    summary = Abroa::ParentOverview.project_for!(@parent, @project.id)
    assert_equal "50.0", summary.dig(:consumption, :net_amount)
    assert_equal "200.0", summary.dig(:funding, :received_amount)
    assert_equal balance, @account.reload.balance
    assert_not_includes summary.to_json, entry.id
  end

  private
    def grant(capability, key: capability.to_s)
      Abroa::Grant.create_for!(@student, @relation.id, project_id: @project.id,
        capability: capability.to_s, key: key)
    end
end
