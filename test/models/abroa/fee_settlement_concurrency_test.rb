require "test_helper"
require "concurrent"
require "timeout"

class Abroa::FeeSettlementConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @user = users(:family_admin)
    @project = Abroa::StudyProject.create_for!(@user, attributes: {
      name: "Fee concurrency", country: "GB", currency: "GBP", timezone: "Europe/London",
      start_on: "2025-01-01", end_on: "2026-12-31" }, key: "fee-concurrent-project")
    @account = Account.create!(family: @user.family, owner: @user, accountable: Depository.new,
      name: "Fee concurrency account", currency: "GBP", balance: 5000)
    @plan = Abroa::FeePlan.create_for!(@user, @project.id, attributes: {
      name: "Terms", kind: "tuition", currency: "GBP", gross_amount: "200",
      discount_amount: "0" }, key: "fee-concurrent-plan")
    @installments = [ "First", "Second" ].map do |name|
      Abroa::FeeInstallment.schedule_for!(@user, @plan.id, attributes: {
        name: name, due_on: "2025-09-01", gross_amount: "100", discount_amount: "0" }, key: name)
    end
    @entry = @account.entries.create!(entryable: Transaction.new, name: "School payment",
      amount: 100, currency: "GBP", date: Date.new(2025, 8, 1))
    @allocation = Abroa::EntryAllocation.allocate_for!(@user, @project.id,
      entry_id: @entry.id, amount: "100", key: "fee-concurrent-entry")
  end

  teardown do
    Abroa::FeeSettlement.where(fee_installment_id: @installments.map(&:id)).delete_all
    Abroa::FeeInstallment.where(id: @installments.map(&:id)).delete_all
    Abroa::FeePlan.where(id: @plan.id).delete_all
    Abroa::EntryAllocation.where(id: @allocation.id).delete_all
    Abroa::StudyProject.where(id: @project.id).delete_all
    @account.destroy!
  end

  test "two database sessions cannot allocate 140 against 100 of ledger facts" do
    results = race(@installments) do |installment, i|
      Abroa::FeeSettlement.pay_for!(User.find(@user.id), installment.id,
        allocation_id: @allocation.id, amount: "70", key: "parallel-#{i}")
    end
    assert_equal [ :accepted, :rejected ], results.sort
    assert_equal BigDecimal("70"), Abroa::FeeSettlement.where(allocation_id: @allocation.id).sum(:amount)
    assert_equal BigDecimal("100"), @entry.reload.amount
  end

  test "simultaneous replay of one key returns the same settlement" do
    results = race([ @installments.first, @installments.first ]) do |installment, _|
      Abroa::FeeSettlement.pay_for!(User.find(@user.id), installment.id,
        allocation_id: @allocation.id, amount: "50", key: "same-claim")
    end
    assert_equal [ :accepted, :accepted ], results.sort
    assert_equal 1, Abroa::FeeSettlement.where(allocation_id: @allocation.id).count
    assert_equal BigDecimal("50"), @installments.first.reload.paid_amount
    assert_equal BigDecimal("100"), @entry.reload.amount
  end

  private
    def race(items)
      gate = Concurrent::CountDownLatch.new(items.length)
      threads = items.each_with_index.map do |item, i|
        Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do
            gate.count_down
            raise "Fee concurrency barrier timed out" unless gate.wait(15)
            yield item, i
            :accepted
          rescue ArgumentError, Abroa::FeePlan::Conflict, Abroa::FeeSettlement::Conflict
            :rejected
          end
        end
      end
      Timeout.timeout(45) { threads.map(&:value) }
    ensure
      threads&.each { |thread| thread.kill if thread.alive?; thread.join }
    end
end
