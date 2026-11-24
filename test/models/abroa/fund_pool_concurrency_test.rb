require "test_helper"
require "concurrent"
require "timeout"

class Abroa::FundPoolConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Pool concurrent", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2027-12-31" }, key: "pool-concurrency")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Pool cash concurrent", currency: "GBP", balance: 100_000)
    @pools = %w[tuition rent].map do |name|
      Abroa::FundPool.create_for!(@user, @project.id, attributes: { name: name, kind: name, currency: "GBP" })
    end
  end

  teardown do
    Abroa::PoolMovement.where(pool_id: @pools.map(&:id)).delete_all
    Abroa::FundPool.where(id: @pools.map(&:id)).delete_all
    Abroa::StudyProject.where(id: @project.id).delete_all
    @account.destroy!
  end

  test "two independent connections never claim 80000 of 70000 free cash" do
    goal = @user.family.goals.create!(name: "Goal locked", target_amount: 30_000, currency: "GBP",
      goal_accounts: [ GoalAccount.new(account: @account, allocated_amount: 30_000) ])
    results = race(@pools) do |pool, i|
      Abroa::PoolMovement.apply_for!(User.find(@user.id), pool.id,
        account_id: @account.id, kind: "allocate", amount: "40000", key: "claim-#{i}")
    end
    assert_equal [ :allocated, :rejected ], results.sort
    assert_equal BigDecimal("40000"), Abroa::PoolMovement.where(account_id: @account.id).sum(:amount)
    assert_equal BigDecimal("70000"), Abroa::AllocationGuard.summary_for!(@user, @account.id)[:reserved_total]
    assert_equal BigDecimal("100000"), @account.reload.balance
  ensure
    goal&.destroy!
  end

  test "a new Sure Goal and an Abroa allocation cannot race past available cash" do
    results = race([ :pool, :goal ]) do |item, i|
      if item == :pool
        Abroa::PoolMovement.apply_for!(User.find(@user.id), @pools.first.id,
          account_id: @account.id, kind: "allocate", amount: "60000", key: "racing-pool")
      else
        family = Family.find(@user.family_id)
        family.goals.create!(name: "Race goal", target_amount: 60_000, currency: "GBP",
          goal_accounts: [ GoalAccount.new(account: Account.find(@account.id), allocated_amount: 60_000) ])
      end
    end
    assert_equal [ :allocated, :rejected ], results.sort
    assert_operator Abroa::AllocationGuard.summary_for!(@user, @account.id)[:reserved_total], :<=, BigDecimal("100000")
  ensure
    @user.family.goals.where(name: "Race goal").destroy_all
  end

  test "concurrent duplicate movement key creates only one event" do
    results = race([ 1, 2 ], errors: [ ArgumentError ]) do
      Abroa::PoolMovement.apply_for!(User.find(@user.id), @pools.first.id,
        account_id: @account.id, kind: "allocate", amount: "5000", key: "same-idempotency")
    end
    assert_equal [ :allocated, :allocated ], results.sort
    assert_equal 1, Abroa::PoolMovement.where(pool_id: @pools.first.id, kind: "allocate").count
    assert_equal BigDecimal("5000"), @pools.first.native_allocated_for(@account)
  end

  private
    def race(items, errors: [ ArgumentError, ActiveRecord::RecordInvalid ])
      barrier = Concurrent::CountDownLatch.new(items.length)
      threads = items.each_with_index.map do |item, i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            barrier.count_down
            raise "Concurrency barrier failed" unless barrier.wait(15)
            yield item, i
            :allocated
          rescue *errors
            :rejected
          end
        end
      end
      Timeout.timeout(45) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
