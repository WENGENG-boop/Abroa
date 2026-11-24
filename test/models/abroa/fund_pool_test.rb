require "test_helper"

class Abroa::FundPoolTest < ActiveSupport::TestCase
  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fund school", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "fund-project")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Student money", currency: "GBP", balance: 100_000)
  end

  test "four virtual allocations conserve bank balance and expose free living amount" do
    names = %w[tuition rent living emergency]
    amounts = [ "50000", "25000", "20000", "5000" ]
    pools = names.map do |name|
      Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: name, currency: "GBP", kind: name })
    end
    assert_no_difference "Entry.count" do
      pools.zip(amounts).each_with_index do |(pool, amount), i|
        Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id, kind: "allocate",
          amount: amount, key: "pool-allocate-#{i}")
      end
    end
    summary = Abroa::AllocationGuard.summary_for!(@user, @account.id)
    assert_equal BigDecimal("100000"), summary[:usable_cash]
    assert_equal BigDecimal("100000"), summary[:reserved_total]
    assert_equal BigDecimal("0"), summary[:unallocated_cash]
    assert_equal BigDecimal("20000"), pools[2].reload.native_allocated_for(@account)
    assert_equal BigDecimal("100000"), @account.reload.balance
  end

  test "Sure Goal reserve and Abroa pools share one native currency ceiling" do
    goal = @user.family.goals.create!(name: "Existing goal", target_amount: 40_000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 40_000) ])
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: "Fees", currency: "GBP", kind: "tuition" })
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "60000", key: "all-remaining")
    assert_equal BigDecimal("60000"), pool.reload.native_allocated_for(@account)
    assert_equal BigDecimal("100000"), Abroa::AllocationGuard.summary_for!(@user, @account.id)[:reserved_total]
    assert_raises(ArgumentError) do
      Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "allocate", amount: "0.0001", key: "over-cap")
    end
    assert_equal BigDecimal("100000"), @account.reload.balance
    assert_equal goal.id, Goal.find(goal.id).id
  end

  test "an added Sure Goal must not overclaim the funds already in a pool" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: "Living", currency: "GBP", kind: "living" })
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "75000", key: "living-75k")
    assert_raises(ActiveRecord::RecordInvalid) do
      @user.family.goals.create!(name: "Impossible goal", target_amount: 30_000, currency: "GBP",
        goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 30_000) ])
    end
    assert_equal BigDecimal("75000"), pool.reload.native_allocated_for(@account)
  end

  test "goal-linked pool is only a view of the original Sure Goal earmark" do
    goal = @user.family.goals.create!(name: "Old rent reserve", target_amount: 40_000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 40_000) ])
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Linked reserve", currency: "GBP", kind: "rent", goal_id: goal.id })
    summary = Abroa::AllocationGuard.summary_for!(@user, @account.id)
    assert_equal BigDecimal("40000"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("40000"), summary[:goal_reserved]
    assert_equal BigDecimal("0"), summary[:pool_reserved]
    assert_equal BigDecimal("40000"), summary[:reserved_total]
    assert_raises(ArgumentError) do
      Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "allocate", amount: "1", key: "double-claim")
    end
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "reserve", amount: "3000", fee_installment_id: SecureRandom.uuid, key: "earmark-fee")
    assert_equal BigDecimal("40000"), Abroa::AllocationGuard.summary_for!(@user, @account.id)[:reserved_total]
    assert_equal BigDecimal("3000"), pool.native_reserved_for(@account)
  end

  test "goal-linked pool consumes the same real posted transaction through Sure Goal" do
    goal = @user.family.goals.create!(name: "Savings for tuition", target_amount: 5000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 5000) ])
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Goal tuition", kind: "tuition", currency: "GBP", goal_id: goal.id })
    purchase = @account.entries.create!(entryable: Transaction.new, name: "Term payment",
      amount: 2000, currency: "GBP", date: Date.current)
    @account.update!(balance: 98_000)
    movement = nil
    assert_no_difference "Entry.count" do
      movement = Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "consume", amount: "2000", entry_id: purchase.id, key: "goal-payment")
    end
    assert_equal BigDecimal("2000"), goal.reload.consumed_amount
    assert_equal BigDecimal("3000"), goal.goal_accounts.first.reload.allocated_amount
    assert_equal BigDecimal("3000"), pool.reload.native_allocated_for(@account)
    assert_equal BigDecimal("3000"), Abroa::AllocationGuard.summary_for!(@user, @account.id)[:goal_reserved]
    assert_equal goal.id, purchase.transaction.reload.extra.dig("goal", "consumed_goal_id")
    assert_equal movement.id, Abroa::PoolMovement.apply_for!(@user, pool.id,
      account_id: @account.id, kind: "consume", amount: "2000", entry_id: purchase.id,
      key: "goal-payment").id
    assert_equal BigDecimal("2000"), goal.reload.consumed_amount
    assert_raises(ArgumentError) do
      Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "consume", amount: "2000", entry_id: purchase.id, key: "double-consumption")
    end
    assert_equal 1, pool.movements.where(kind: "consume").count
  end

  test "goal-linked refund restores original earmark only for an authoritative refund" do
    goal = @user.family.goals.create!(name: "One off tuition", target_amount: 5000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 5000) ])
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Linked tuition", kind: "tuition", currency: "GBP", goal_id: goal.id })
    expense = @account.entries.create!(entryable: Transaction.new, name: "School fee",
      amount: 2000, currency: "GBP", date: Date.current)
    @account.update!(balance: 98_000)
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "consume", amount: "2000", entry_id: expense.id, key: "goal-fee")
    assert_equal BigDecimal("3000"), goal.goal_accounts.first.reload.allocated_amount
    refund = @account.entries.create!(entryable: Transaction.new, name: "School adjustment",
      amount: -700, currency: "GBP", date: Date.current)
    Abroa::RefundLink.link_for!(@user, original_entry_id: expense.id, refund_entry_id: refund.id,
      applied_amount: "700", refund_amount: "700")
    @account.update!(balance: 98_700)
    assert_no_difference "Entry.count" do
      first = Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "refund", amount: "700", entry_id: refund.id, key: "goal-refund")
      assert_equal first.id, Abroa::PoolMovement.apply_for!(@user, pool.id,
        account_id: @account.id, kind: "refund", amount: "700",
        entry_id: refund.id, key: "goal-refund").id
    end
    assert_equal BigDecimal("1300"), goal.reload.consumed_amount
    account_link = goal.goal_accounts.first
    account_link.reload
    assert_equal BigDecimal("3700"), account_link.allocated_amount
    assert_equal BigDecimal("3700"), Abroa::AllocationGuard.summary_for!(@user, @account.id)[:reserved_total]
    assert_raises(ArgumentError) do
      Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "refund", amount: "1", entry_id: refund.id, key: "refund-over")
    end
    assert_equal BigDecimal("1300"), goal.reload.consumed_amount
  end

  test "maintained Sure Goal consumption is refused without creating phantom pool movement" do
    goal = @user.family.goals.create!(name: "Emergency reserve", kind: "maintained",
      target_amount: 5000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 5000) ])
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "Emergency", kind: "emergency", currency: "GBP", goal_id: goal.id })
    expense = @account.entries.create!(entryable: Transaction.new, name: "Emergency invoice",
      amount: 200, currency: "GBP", date: Date.current)
    assert_no_difference "Abroa::PoolMovement.count" do
      assert_raises(Goal::ConsumptionRefused) do
        Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
          kind: "consume", amount: "200", entry_id: expense.id, key: "not-allowed")
      end
    end
    assert_nil expense.transaction.reload.extra&.dig("goal", "consumed_goal_id")
    assert_equal BigDecimal("0"), goal.reload.consumed_amount
    assert_equal BigDecimal("5000"), pool.native_allocated_for(@account)
  end

  test "restoring an archived Sure Goal must not overclaim active fund pools" do
    goal = @user.family.goals.create!(name: "Released goal", target_amount: 40_000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 40_000) ])
    goal.archive!
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: {
      name: "New commitments", currency: "GBP", kind: "tuition" })
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "80000", key: "claim-after-release")
    assert_equal "archived", goal.reload.state
    assert_equal 1, goal.goal_accounts.count
    assert_equal BigDecimal("80000"), Abroa::PoolMovement.native_allocated_for(@account)
    goal.state = "active"
    assert_not goal.valid?, "Archived goal restoration must be refused: #{goal.errors.full_messages.join(", ")}"
    goal.reload
    assert_not goal.unarchive!, "AASM transition must refuse invalid restoration"
    assert_equal "archived", goal.reload.state
    assert_equal BigDecimal("80000"), Abroa::AllocationGuard.summary_for!(@user, @account.id)[:reserved_total]
  end

  test "release reserve consume and linked refund never create a second payment" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: "Tuition", currency: "GBP", kind: "tuition" })
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "10000", key: "allocate")
    fee_id = SecureRandom.uuid
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "reserve", amount: "4000", fee_installment_id: fee_id, key: "reserve")
    assert_equal BigDecimal("4000"), pool.native_reserved_for(@account)
    assert_equal BigDecimal("10000"), pool.native_allocated_for(@account)
    purchase = @account.entries.create!(entryable: Transaction.new, name: "School bill", amount: 3000,
      currency: "GBP", date: Date.current)
    @account.update!(balance: 97_000)
    before = Entry.count
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "consume", amount: "3000", entry_id: purchase.id, fee_installment_id: fee_id, key: "consume")
    assert_equal before, Entry.count
    assert_equal BigDecimal("7000"), pool.native_allocated_for(@account)
    assert_equal BigDecimal("1000"), pool.native_reserved_for(@account)
    refund = @account.entries.create!(entryable: Transaction.new, name: "School refund", amount: -1000,
      currency: "GBP", date: Date.current)
    Abroa::RefundLink.link_for!(@user, original_entry_id: purchase.id, refund_entry_id: refund.id,
      applied_amount: "1000", refund_amount: "1000")
    @account.update!(balance: 98_000)
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "refund", amount: "1000", entry_id: refund.id, key: "refund")
    assert_equal BigDecimal("8000"), pool.reload.native_allocated_for(@account)
    assert_equal BigDecimal("1000"), pool.native_reserved_for(@account)
    assert_equal BigDecimal("98000"), @account.reload.balance
  end

  test "external spending reports a funding shortfall instead of reducing pledged allocations" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: "Tuition", currency: "GBP", kind: "tuition" })
    Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "90000", key: "allocate")
    @account.update!(balance: 70_000)
    summary = Abroa::AllocationGuard.summary_for!(@user, @account.id)
    assert_equal BigDecimal("20000"), summary[:shortfall]
    assert_equal BigDecimal("90000"), summary[:reserved_total]
    assert_equal BigDecimal("0"), summary[:unallocated_cash]
    assert_raises(ArgumentError) do
      Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "allocate", amount: "1", key: "cannot-allocate-while-short")
    end
  end

  test "replaying a movement is idempotent and a changed request is rejected" do
    pool = Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: "Rent", currency: "GBP", kind: "rent" })
    first = Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "1000", key: "one")
    second = Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
      kind: "allocate", amount: "1000", key: "one")
    assert_equal first.id, second.id
    assert_raises(Abroa::FundPool::Conflict) do
      Abroa::PoolMovement.apply_for!(@user, pool.id, account_id: @account.id,
        kind: "allocate", amount: "2000", key: "one")
    end
    assert_equal BigDecimal("1000"), pool.native_allocated_for(@account)
  end
end
