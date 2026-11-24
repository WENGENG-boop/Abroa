require "test_helper"

class Abroa::BudgetNodeTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Budget project", country: "GB", timezone: "Europe/London", currency: "GBP",
      start_on: "2025-01-01", end_on: "2026-12-31" }, key: "budget-project")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Budget cash", currency: "GBP", balance: 1000)
    @entry = @account.entries.create!(entryable: Transaction.new, name: "Rent", amount: 200,
      currency: "GBP", date: Date.new(2025, 2, 1))
    Abroa::EntryAllocation.allocate_for!(@user, @project.id, entry_id: @entry.id, amount: "200")
    @year = create_budget("Year", "2025-01-01", "2025-12-31", "1000")
  end

  test "one transaction counts once per matching level but not three times in ledger" do
    term = create_budget("Term", "2025-01-01", "2025-06-30", "800", parent_id: @year.id)
    month = create_budget("Month", "2025-02-01", "2025-02-28", "500", parent_id: term.id)
    [ @year, term, month ].each do |node|
      report = node.execution_for!(@user)
      assert_equal BigDecimal("200"), report.fetch(:actual)
    end
    assert_equal BigDecimal("200"), @entry.reload.amount
    assert_equal BigDecimal("200"), @project.allocations.sum(:amount)
  end

  test "child budget over-allocation warns without rewriting the ledger" do
    create_budget("Spring", "2025-01-01", "2025-06-30", "600", parent_id: @year.id)
    create_budget("Autumn", "2025-07-01", "2025-12-31", "600", parent_id: @year.id)
    report = @year.execution_for!(@user)
    assert_includes report[:warnings], "child_limits_exceed_parent"
    assert_equal BigDecimal("1200"), report[:child_limits_total]
    assert_equal BigDecimal("200"), report[:actual]
    assert_equal BigDecimal("200"), @entry.reload.amount
  end

  test "committed obligations and earmarked cash never subtract twice" do
    node = @year
    node.update!(limit_amount: 1000)
    report = node.execution_for!(@user, committed_amount: "300", reserved_for_same_obligation: "300")
    assert_equal BigDecimal("800"), report[:remaining]
    assert_equal BigDecimal("500"), report[:uncommitted_remaining]
  end

  test "invalid overlaps cycles and project cross references reject" do
    term = create_budget("Term", "2025-01-01", "2025-06-30", "300", parent_id: @year.id)
    assert_raises(ActiveRecord::RecordInvalid) do
      create_budget("Duplicate term", "2025-04-01", "2025-09-30", "200", parent_id: @year.id)
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::BudgetNode.change_for!(@user, @year.id, version: @year.reload.lock_version,
        attributes: { parent_id: term.id })
    end
    assert_raises(ActiveRecord::RecordInvalid) do
      Abroa::BudgetNode.change_for!(@user, @year.id, version: @year.reload.lock_version,
        attributes: { start_on: "2025-03-01" })
    end
  end

  test "refund reduces the actual on its receipt date, not the purchase date" do
    refund = @account.entries.create!(entryable: Transaction.new, name: "Rent refund", amount: -50,
      currency: "GBP", date: Date.new(2025, 3, 5))
    Abroa::RefundLink.link_for!(@user, original_entry_id: @entry.id, refund_entry_id: refund.id,
      applied_amount: "50", refund_amount: "50")
    february = create_budget("February", "2025-02-01", "2025-02-28", "500", parent_id: @year.id)
    march = create_budget("March", "2025-03-01", "2025-03-31", "500", parent_id: @year.id)
    assert_equal BigDecimal("200"), february.execution_for!(@user)[:actual]
    assert_equal BigDecimal("-50"), march.execution_for!(@user)[:actual]
    assert_equal BigDecimal("150"), @year.execution_for!(@user)[:actual]
    assert_equal BigDecimal("200"), @entry.reload.amount
    assert_equal BigDecimal("-50"), refund.reload.amount
  end

  test "closed period rollover is idempotent and versioned" do
    next_node = Abroa::BudgetNode.create_for!(@user, @project.id, attributes: {
      name: "Next year", start_on: "2026-01-01", end_on: "2026-12-31", currency: "GBP",
      limit_amount: "300", rollover_enabled: true })
    @year.update!(status: "closed", rollover_enabled: true)
    first = Abroa::BudgetNode.rollover_for!(@user, @year.id, target_id: next_node.id, key: "roll-one")
    second = Abroa::BudgetNode.rollover_for!(@user, @year.id, target_id: next_node.id, key: "roll-one")
    assert_equal first.id, second.id
    assert_equal BigDecimal("800"), next_node.reload.rollover_amount
    assert_equal 1, Abroa::BudgetVersion.where(operation_key: "roll-one").count
    assert_raises(Abroa::BudgetNode::Conflict) do
      Abroa::BudgetNode.rollover_for!(@user, @year.id, target_id: next_node.id, key: "another-key")
    end
  end

  private
    def create_budget(name, start_on, end_on, limit, parent_id: nil)
      Abroa::BudgetNode.create_for!(@user, @project.id, attributes: {
        name: name, start_on: start_on, end_on: end_on, currency: "GBP",
        limit_amount: limit, parent_id: parent_id })
    end
end
